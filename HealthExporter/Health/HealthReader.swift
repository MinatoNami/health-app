import Foundation
import HealthKit
import UIKit

/// All HealthKit reads live here, wrapped in async/await.
///
/// Uses the classic callback query APIs rather than the newer query descriptors:
/// the callback surface is stable across every OS version this app supports, and
/// each wrapper guards against double-resume, which is the one way a
/// continuation can turn a HealthKit quirk into a crash.
final class HealthReader {

    enum ReadError: LocalizedError {
        case healthDataUnavailable
        case protectedDataUnavailable
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable:
                return "HealthKit is not available on this device."
            case .protectedDataUnavailable:
                return "Device is locked — HealthKit is encrypted and cannot be read yet."
            case .queryFailed(let message):
                return message
            }
        }
    }

    /// A page of changes, already normalised.
    ///
    /// Deliberately carries `HealthRecord` values rather than `HKSample`
    /// objects. Normalising here means it happens on the queue HealthKit
    /// delivers results on, instead of on the main actor — it was the last piece
    /// of per-sample CPU work left on the main thread, and two thousand samples
    /// of it cannot be broken up by yielding.
    ///
    /// It is also the safer boundary: `HKSample` is a non-`Sendable`
    /// Objective-C object, and handing arrays of them between actors is
    /// something Swift 6 will refuse outright. Structs cross freely.
    struct AnchoredPage {
        var records: [HealthRecord]
        var newAnchor: HKQueryAnchor?
        /// Newest `endDate` among the samples that were emitted, for the anchor
        /// bookkeeping. Nil when the page emitted nothing.
        var newestEnd: Date?
        /// A full page almost certainly means more is waiting. Counted from the
        /// samples *read*, not the records kept — a page entirely below the
        /// cutoff emits nothing and is not the end of the data.
        var likelyHasMore: Bool
    }

    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    /// HealthKit encrypts its store while the device is locked; reads fail with
    /// `errorDatabaseInaccessible`. A background wake can easily land in that
    /// window, and the failure must not be mistaken for "no data".
    @MainActor
    static var isReadable: Bool {
        UIApplication.shared.isProtectedDataAvailable
    }

    // MARK: - Anchored reads

    /// One page of changes since `anchor`, normalised on HealthKit's own queue.
    ///
    /// Returns added samples *and* deleted object UUIDs — the only query that
    /// reports deletions, which is why it's the backbone of sync rather than
    /// `HKSampleQuery`.
    ///
    /// `cutoff` is applied here rather than by the caller: a sample older than
    /// the backfill start is dropped before it is ever normalised, so the anchor
    /// still advances over ancient history without paying to convert it.
    func anchoredPage(type: HKSampleType,
                      anchor: HKQueryAnchor?,
                      limit: Int,
                      cutoff: Date) async throws -> AnchoredPage {
        guard await HealthReader.isReadable else { throw ReadError.protectedDataUnavailable }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGuard()
            // No `updateHandler` is set, so this is a one-shot query: the results
            // handler fires exactly once. The guard is belt-and-braces.
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: nil,
                anchor: anchor,
                limit: limit
            ) { _, samples, deleted, newAnchor, error in
                guard resumed.claim() else { return }
                if let error {
                    continuation.resume(throwing: ReadError.queryFailed(error.localizedDescription))
                    return
                }
                let added = samples ?? []
                let removed = deleted ?? []

                var records: [HealthRecord] = []
                records.reserveCapacity(added.count + removed.count)
                var newestEnd: Date?

                for sample in added {
                    // HealthKit samples are Objective-C objects that pile up in
                    // the autorelease pool. Without draining it per sample, a
                    // page of 2,000 — times hundreds of pages — is a steady
                    // climb to a jetsam kill rather than flat memory use.
                    autoreleasepool {
                        guard sample.endDate >= cutoff else { return }
                        if let record = Normalizer.record(from: sample) {
                            records.append(record)
                            if sample.endDate > (newestEnd ?? .distantPast) {
                                newestEnd = sample.endDate
                            }
                        }
                    }
                }
                // Tombstones carry no type or date, only a UUID. Emitting them is
                // what keeps the destination from diverging permanently.
                for object in removed {
                    records.append(HealthRecord.deletion(uuid: object.uuid))
                }

                continuation.resume(returning: AnchoredPage(
                    records: records,
                    newAnchor: newAnchor,
                    newestEnd: newestEnd,
                    likelyHasMore: added.count + removed.count >= limit
                ))
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Daily statistics

    /// Apple-deduplicated daily rollups.
    ///
    /// This matters more than it looks: iPhone and Apple Watch both write step
    /// counts, so raw samples overlap and double-count. Statistics queries merge
    /// across sources the way the Health app does; `HKSampleQuery` does not. Raw
    /// samples are still exported for provenance, but these are the numbers a
    /// workflow should actually consume.
    func dailyStatistics(type: HKQuantityType,
                         from start: Date,
                         to end: Date) async throws -> [HKStatistics] {
        guard await HealthReader.isReadable else { throw ReadError.protectedDataUnavailable }

        // Anchor on local midnight: day boundaries must follow the user's
        // calendar, or step counts land on the wrong day when travelling.
        let calendar = Calendar.current
        let anchorDate = calendar.startOfDay(for: start)

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGuard()
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end,
                                                                     options: .strictStartDate),
                options: type.statisticsOptions,
                anchorDate: anchorDate,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                guard resumed.claim() else { return }
                if let error {
                    continuation.resume(throwing: ReadError.queryFailed(error.localizedDescription))
                    return
                }
                guard let collection else {
                    continuation.resume(returning: [])
                    return
                }
                var out: [HKStatistics] = []
                collection.enumerateStatistics(from: start, to: end) { stats, _ in
                    out.append(stats)
                }
                continuation.resume(returning: out)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Characteristics

    /// Static profile data. Read once — polling these is pointless.
    func characteristics() -> [HealthRecord] {
        var records: [HealthRecord] = []
        let now = Date()
        let stamp = Timestamps.iso8601(now)

        func emit(_ identifier: String, value: Double?, label: String?) {
            records.append(HealthRecord(
                id: "characteristic:\(identifier)",
                kind: .characteristic,
                metric: identifier,
                metricSlug: identifier.healthKitSlug,
                value: value,
                valueLabel: label,
                start: stamp,
                end: stamp,
                recordedAt: stamp
            ))
        }

        if let components = try? healthStore.dateOfBirthComponents(),
           let date = Calendar.current.date(from: components) {
            emit("HKCharacteristicTypeIdentifierDateOfBirth",
                 value: nil,
                 label: Timestamps.iso8601(date))
        }
        if let sex = try? healthStore.biologicalSex() {
            emit("HKCharacteristicTypeIdentifierBiologicalSex",
                 value: Double(sex.biologicalSex.rawValue),
                 label: sex.biologicalSex.label)
        }
        if let blood = try? healthStore.bloodType() {
            emit("HKCharacteristicTypeIdentifierBloodType",
                 value: Double(blood.bloodType.rawValue),
                 label: blood.bloodType.label)
        }
        if let skin = try? healthStore.fitzpatrickSkinType() {
            emit("HKCharacteristicTypeIdentifierFitzpatrickSkinType",
                 value: Double(skin.skinType.rawValue),
                 label: skin.skinType.label)
        }
        if let chair = try? healthStore.wheelchairUse() {
            emit("HKCharacteristicTypeIdentifierWheelchairUse",
                 value: Double(chair.wheelchairUse.rawValue),
                 label: chair.wheelchairUse == .yes ? "yes" : "no")
        }
        return records
    }
}

/// Ensures a continuation is resumed at most once. HealthKit's handlers are
/// documented as one-shot for the queries used here, but a double resume is an
/// immediate crash, so it's cheap insurance.
/// `@unchecked` is honest here rather than a silencer: the only mutable state
/// is `used`, and every read and write of it happens under `lock`. The compiler
/// cannot see that, but the HealthKit callbacks that capture this are handed to
/// a `@Sendable` closure and genuinely may arrive on any thread.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

// MARK: - Enum labels

extension HKBiologicalSex {
    var label: String {
        switch self {
        case .female: return "female"
        case .male: return "male"
        case .other: return "other"
        case .notSet: return "not_set"
        @unknown default: return "unknown"
        }
    }
}

extension HKBloodType {
    var label: String {
        switch self {
        case .aPositive: return "A+"
        case .aNegative: return "A-"
        case .bPositive: return "B+"
        case .bNegative: return "B-"
        case .abPositive: return "AB+"
        case .abNegative: return "AB-"
        case .oPositive: return "O+"
        case .oNegative: return "O-"
        case .notSet: return "not_set"
        @unknown default: return "unknown"
        }
    }
}

extension HKFitzpatrickSkinType {
    var label: String {
        switch self {
        case .I: return "I"
        case .II: return "II"
        case .III: return "III"
        case .IV: return "IV"
        case .V: return "V"
        case .VI: return "VI"
        case .notSet: return "not_set"
        @unknown default: return "unknown"
        }
    }
}
