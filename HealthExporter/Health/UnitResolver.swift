import Foundation
import HealthKit

/// Picks a unit for every quantity type — without ever crashing.
///
/// HealthKit throws if you ask a quantity for a value in an incompatible unit,
/// and there is no public API that maps a type to its valid units. Hard-coding
/// a table of ~170 units from documentation is therefore a table of ~170 chances
/// to crash at runtime.
///
/// So this resolves units *from the data*: try a preferred unit, verify with
/// `is(compatibleWith:)`, and fall back through a ladder covering every
/// dimension HealthKit uses. A wrong preference costs a slightly odd unit
/// choice; it can never throw. Results are cached per type.
final class UnitResolver {
    static let shared = UnitResolver()

    private let lock = NSLock()
    private var cache: [String: HKUnit] = [:]

    /// Ordered by specificity: anything ambiguous (a bare `count`, a duration)
    /// must come after the compound units that would also match it, or e.g.
    /// heart rate would resolve as a dimensionless count.
    private lazy var ladder: [HKUnit] = {
        var units: [HKUnit] = [
            // Rates and compound units first.
            HKUnit.count().unitDivided(by: .minute()),
            HKUnit.count().unitDivided(by: .second()),
            HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())),
            HKUnit.kilocalorie()
                .unitDivided(by: HKUnit.hour().unitMultiplied(by: HKUnit.gramUnit(with: .kilo))),
            HKUnit.liter().unitDivided(by: .minute()),
            HKUnit.meter().unitDivided(by: .second()),
            HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)),

            // Named dimensions.
            HKUnit.millimeterOfMercury(),
            HKUnit.decibelAWeightedSoundPressureLevel(),
            HKUnit.decibelHearingLevel(),
            HKUnit.siemenUnit(with: .micro),
            HKUnit.internationalUnit(),
            HKUnit.watt(),
            HKUnit.volt(),
            HKUnit.degreeCelsius(),
            HKUnit.percent(),

            // Mass, length, volume, energy.
            HKUnit.gramUnit(with: .kilo),
            HKUnit.gram(),
            HKUnit.gramUnit(with: .milli),
            HKUnit.gramUnit(with: .micro),
            HKUnit.meter(),
            HKUnit.liter(),
            HKUnit.literUnit(with: .milli),
            HKUnit.kilocalorie(),

            // Durations and bare counts last: many things are compatible with
            // these, so they act as the catch-all.
            HKUnit.minute(),
            HKUnit.second(),
            HKUnit.secondUnit(with: .milli),
            HKUnit.count()
        ]
        if #available(iOS 18.0, *) {
            units.insert(HKUnit.appleEffortScore(), at: 0)
        }
        return units
    }()

    /// Preferences that make the output nicer to consume. Purely advisory — each
    /// one is compatibility-checked before use, so a mistake here is harmless.
    private func preferred(for identifier: String) -> HKUnit? {
        switch identifier {
        case HKQuantityTypeIdentifier.stepCount.rawValue,
             HKQuantityTypeIdentifier.flightsClimbed.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.heartRate.rawValue,
             HKQuantityTypeIdentifier.restingHeartRate.rawValue,
             HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue,
             HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            return HKUnit.secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue:
            return .kilocalorie()
        case HKQuantityTypeIdentifier.bodyMass.rawValue,
             HKQuantityTypeIdentifier.leanBodyMass.rawValue:
            return HKUnit.gramUnit(with: .kilo)
        case HKQuantityTypeIdentifier.height.rawValue,
             HKQuantityTypeIdentifier.waistCircumference.rawValue,
             HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
             HKQuantityTypeIdentifier.distanceCycling.rawValue,
             HKQuantityTypeIdentifier.distanceSwimming.rawValue:
            return .meter()
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
             HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
             HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue,
             HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue:
            return .percent()
        case HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
             HKQuantityTypeIdentifier.appleStandTime.rawValue,
             HKQuantityTypeIdentifier.appleMoveTime.rawValue:
            return .minute()
        case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue,
             HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
            return .millimeterOfMercury()
        case HKQuantityTypeIdentifier.bloodGlucose.rawValue:
            return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case HKQuantityTypeIdentifier.bodyTemperature.rawValue,
             HKQuantityTypeIdentifier.basalBodyTemperature.rawValue:
            return .degreeCelsius()
        case HKQuantityTypeIdentifier.vo2Max.rawValue:
            return HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case HKQuantityTypeIdentifier.bodyMassIndex.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.dietaryWater.rawValue:
            return .literUnit(with: .milli)
        case HKQuantityTypeIdentifier.dietaryCaffeine.rawValue,
             HKQuantityTypeIdentifier.dietarySodium.rawValue:
            return HKUnit.gramUnit(with: .milli)
        case HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue,
             HKQuantityTypeIdentifier.dietaryProtein.rawValue,
             HKQuantityTypeIdentifier.dietaryFatTotal.rawValue,
             HKQuantityTypeIdentifier.dietaryFiber.rawValue,
             HKQuantityTypeIdentifier.dietarySugar.rawValue:
            return .gram()
        default:
            return nil
        }
    }

    /// Resolve using an actual sample's quantity, which carries the dimension.
    func unit(for type: HKQuantityType, quantity: HKQuantity) -> HKUnit {
        let key = type.identifier
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            // Trust the cache only if it still fits; different sources should
            // never disagree on dimension, but verifying costs nothing.
            if quantity.`is`(compatibleWith: cached) { return cached }
        } else {
            lock.unlock()
        }

        var resolved: HKUnit?
        if let hint = preferred(for: key), quantity.`is`(compatibleWith: hint) {
            resolved = hint
        } else {
            resolved = ladder.first { quantity.`is`(compatibleWith: $0) }
        }

        guard let unit = resolved else {
            // No known dimension matched. Extremely unlikely, but returning a
            // count would throw, so signal it and let the caller skip.
            Log.shared.error("units", "No compatible unit found for \(key)")
            return HKUnit.count()
        }

        lock.lock()
        cache[key] = unit
        lock.unlock()
        return unit
    }

    /// Safe extraction: returns nil rather than throwing if nothing fits.
    func value(from quantity: HKQuantity, type: HKQuantityType) -> (Double, HKUnit)? {
        let unit = self.unit(for: type, quantity: quantity)
        guard quantity.`is`(compatibleWith: unit) else { return nil }
        return (quantity.doubleValue(for: unit), unit)
    }

    /// Unit for a type when no sample is in hand — needed by statistics queries.
    /// Only trusted for the curated statistics list.
    func staticUnit(for type: HKQuantityType) -> HKUnit? {
        lock.lock()
        let cached = cache[type.identifier]
        lock.unlock()
        return cached ?? preferred(for: type.identifier)
    }
}

extension HKQuantityType {
    /// `cumulative` means the value accrues over the sample's interval and
    /// summing is valid. `discrete` means it's a reading at a point in time and
    /// summing is meaningless — worth carrying downstream so nobody sums heart
    /// rates.
    var recordAggregation: HealthRecord.Aggregation {
        aggregationStyle == .cumulative ? .cumulative : .discrete
    }

    var statisticsOptions: HKStatisticsOptions {
        aggregationStyle == .cumulative
            ? [.cumulativeSum]
            : [.discreteAverage, .discreteMin, .discreteMax]
    }
}
