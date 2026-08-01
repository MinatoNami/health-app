import Foundation
import HealthKit

/// Turns HealthKit's class hierarchy into flat `HealthRecord`s.
enum Normalizer {

    /// Returns nil for samples that can't be represented safely — better to skip
    /// one sample and log it than to emit a record with a meaningless value.
    static func record(from sample: HKSample) -> HealthRecord? {
        switch sample {
        case let workout as HKWorkout:
            return workoutRecord(workout)
        case let quantity as HKQuantitySample:
            return quantityRecord(quantity)
        case let category as HKCategorySample:
            return categoryRecord(category)
        default:
            Log.shared.debug("normalize", "Skipped unsupported sample class \(type(of: sample))")
            return nil
        }
    }

    // MARK: - Quantity

    private static func quantityRecord(_ sample: HKQuantitySample) -> HealthRecord? {
        let type = sample.quantityType
        guard let (value, unit) = UnitResolver.shared.value(from: sample.quantity, type: type) else {
            Log.shared.warn("normalize", "No compatible unit for \(type.identifier); sample skipped")
            return nil
        }

        let zone = Timestamps.timeZone(fromMetadata: sample.metadata)
        return HealthRecord(
            id: sample.uuid.uuidString,
            kind: .quantity,
            metric: type.identifier,
            metricSlug: type.identifier.healthKitSlug,
            value: value,
            unit: unit.unitString,
            start: Timestamps.iso8601(sample.startDate, timeZone: zone ?? .current),
            end: Timestamps.iso8601(sample.endDate, timeZone: zone ?? .current),
            tz: (zone ?? .current).identifier,
            aggregation: type.recordAggregation,
            source: source(from: sample),
            device: sample.device?.name,
            metadata: metadata(from: sample.metadata),
            recordedAt: Timestamps.iso8601(Date())
        )
    }

    // MARK: - Category

    private static func categoryRecord(_ sample: HKCategorySample) -> HealthRecord {
        let type = sample.categoryType
        let zone = Timestamps.timeZone(fromMetadata: sample.metadata)
        let isSleep = type.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue

        var extra: [String: JSONValue] = [:]
        if isSleep {
            // A night is dozens of interval samples, one per stage transition.
            // Duration is derived here so downstream doesn't have to re-do date
            // maths just to total up time asleep.
            extra["duration_seconds"] = .number(sample.endDate.timeIntervalSince(sample.startDate))
            extra["is_asleep"] = .bool(SleepLabels.isAsleep(sample.value))
        }

        return HealthRecord(
            id: sample.uuid.uuidString,
            kind: isSleep ? .sleep : .category,
            metric: type.identifier,
            metricSlug: type.identifier.healthKitSlug,
            value: Double(sample.value),
            valueLabel: label(for: sample),
            start: Timestamps.iso8601(sample.startDate, timeZone: zone ?? .current),
            end: Timestamps.iso8601(sample.endDate, timeZone: zone ?? .current),
            tz: (zone ?? .current).identifier,
            aggregation: .discrete,
            source: source(from: sample),
            device: sample.device?.name,
            metadata: metadata(from: sample.metadata),
            extra: extra.isEmpty ? nil : extra,
            recordedAt: Timestamps.iso8601(Date())
        )
    }

    private static func label(for sample: HKCategorySample) -> String? {
        if sample.categoryType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
            return SleepLabels.name(for: sample.value)
        }
        return nil
    }

    // MARK: - Workout

    private static func workoutRecord(_ workout: HKWorkout) -> HealthRecord {
        let zone = Timestamps.timeZone(fromMetadata: workout.metadata)
        var extra: [String: JSONValue] = [
            "activity_type": .number(Double(workout.workoutActivityType.rawValue)),
            "activity_name": .string(workout.workoutActivityType.name),
            "duration_seconds": .number(workout.duration)
        ]

        // `totalEnergyBurned` and friends are deprecated in favour of
        // `statistics(for:)`, which also avoids assuming a unit.
        if let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
           let sum = workout.statistics(for: energyType)?.sumQuantity() {
            extra["active_energy_kcal"] = .number(sum.doubleValue(for: .kilocalorie()))
        }
        if let distanceType = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning),
           let sum = workout.statistics(for: distanceType)?.sumQuantity() {
            extra["distance_m"] = .number(sum.doubleValue(for: .meter()))
        }
        if let events = workout.workoutEvents, !events.isEmpty {
            extra["events"] = .array(events.map { event in
                .compacting([
                    "type": .number(Double(event.type.rawValue)),
                    "start": .string(Timestamps.iso8601(event.dateInterval.start, timeZone: zone ?? .current)),
                    "end": .string(Timestamps.iso8601(event.dateInterval.end, timeZone: zone ?? .current))
                ])
            })
        }

        return HealthRecord(
            id: workout.uuid.uuidString,
            kind: .workout,
            metric: "HKWorkoutTypeIdentifier",
            metricSlug: "workout",
            value: workout.duration,
            unit: "s",
            valueLabel: workout.workoutActivityType.name,
            start: Timestamps.iso8601(workout.startDate, timeZone: zone ?? .current),
            end: Timestamps.iso8601(workout.endDate, timeZone: zone ?? .current),
            tz: (zone ?? .current).identifier,
            aggregation: .cumulative,
            source: source(from: workout),
            device: workout.device?.name,
            metadata: metadata(from: workout.metadata),
            extra: extra,
            recordedAt: Timestamps.iso8601(Date())
        )
    }

    // MARK: - Statistics

    /// Deterministic ID per metric+day, so re-emitting an overlapping window is
    /// a harmless upsert rather than a duplicate row. That's what lets the sync
    /// engine re-send recent days on every run without bookkeeping.
    static func statisticRecord(_ stats: HKStatistics, unit: HKUnit) -> HealthRecord? {
        let type = stats.quantityType
        let day = DateFormatter.dayKey.string(from: stats.startDate)

        var value: Double?
        var extra: [String: JSONValue] = ["day": .string(day)]

        if let sum = stats.sumQuantity(), sum.`is`(compatibleWith: unit) {
            value = sum.doubleValue(for: unit)
            extra["aggregate"] = .string("sum")
        } else if let avg = stats.averageQuantity(), avg.`is`(compatibleWith: unit) {
            value = avg.doubleValue(for: unit)
            extra["aggregate"] = .string("average")
            if let min = stats.minimumQuantity(), min.`is`(compatibleWith: unit) {
                extra["min"] = .number(min.doubleValue(for: unit))
            }
            if let max = stats.maximumQuantity(), max.`is`(compatibleWith: unit) {
                extra["max"] = .number(max.doubleValue(for: unit))
            }
        }
        guard let value else { return nil }

        // How many distinct sources contributed — a quick way to spot which
        // metrics needed deduplication in the first place.
        extra["source_count"] = .number(Double(stats.sources?.count ?? 0))

        return HealthRecord(
            id: "stat:\(type.identifier.healthKitSlug):\(day)",
            kind: .statistic,
            metric: type.identifier,
            metricSlug: type.identifier.healthKitSlug,
            value: value,
            unit: unit.unitString,
            start: Timestamps.iso8601(stats.startDate),
            end: Timestamps.iso8601(stats.endDate),
            tz: TimeZone.current.identifier,
            aggregation: type.recordAggregation,
            extra: extra,
            recordedAt: Timestamps.iso8601(Date())
        )
    }

    // MARK: - Shared

    private static func source(from sample: HKSample) -> HealthRecord.Source {
        let revision = sample.sourceRevision
        return HealthRecord.Source(
            name: revision.source.name,
            bundleId: revision.source.bundleIdentifier,
            productType: revision.productType,
            osVersion: {
                let v = revision.operatingSystemVersion
                return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            }()
        )
    }

    private static func metadata(from metadata: [String: Any]?) -> [String: JSONValue]? {
        guard let metadata, !metadata.isEmpty else { return nil }
        return metadata.mapValues { JSONValue.from($0) }
    }
}

extension DateFormatter {
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar.current
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// `HKCategoryValueSleepAnalysis` raw values, mapped to stable names. Stage
/// detail (core/deep/REM) arrived in iOS 16; older data uses `asleepUnspecified`.
enum SleepLabels {
    static func name(for raw: Int) -> String {
        guard let value = HKCategoryValueSleepAnalysis(rawValue: raw) else { return "unknown_\(raw)" }
        switch value {
        case .inBed: return "inBed"
        case .asleepUnspecified: return "asleepUnspecified"
        case .awake: return "awake"
        case .asleepCore: return "asleepCore"
        case .asleepDeep: return "asleepDeep"
        case .asleepREM: return "asleepREM"
        @unknown default: return "unknown_\(raw)"
        }
    }

    static func isAsleep(_ raw: Int) -> Bool {
        guard let value = HKCategoryValueSleepAnalysis(rawValue: raw) else { return false }
        switch value {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: return true
        case .inBed, .awake: return false
        @unknown default: return false
        }
    }
}
