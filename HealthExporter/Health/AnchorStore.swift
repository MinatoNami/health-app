import Foundation
import HealthKit

/// Persisted `HKQueryAnchor` per sample type, plus per-type sync bookkeeping.
///
/// The anchor is the sync cursor. The single most important rule in this file:
/// **an anchor is only advanced after the data it covers has been durably
/// written.** Persisting it earlier means a failure loses data silently, with
/// nothing left to indicate the gap ever existed.
final class AnchorStore {
    static let shared = AnchorStore()

    struct TypeState: Codable {
        /// `HKQueryAnchor` archived with `NSKeyedArchiver`.
        var anchorData: Data?
        var lastSyncedAt: Date?
        var lastSampleEnd: Date?
        var totalRecords: Int = 0
        var lastError: String?
        /// Set when an observer fires; cleared once the type is drained. Survives
        /// termination, so a wake-up we couldn't service isn't forgotten.
        var dirty: Bool = false
    }

    private let store = StateStore<[String: TypeState]>(filename: "anchors.json", fallback: [:])

    // MARK: - Anchors

    func anchor(for typeIdentifier: String) -> HKQueryAnchor? {
        guard let data = store.value[typeIdentifier]?.anchorData else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        } catch {
            Log.shared.warn("anchors", "Unreadable anchor for \(typeIdentifier); restarting from scratch")
            return nil
        }
    }

    func setAnchor(_ anchor: HKQueryAnchor?, for typeIdentifier: String,
                   lastSampleEnd: Date?, added: Int) {
        let data: Data? = anchor.flatMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        store.mutate { state in
            var entry = state[typeIdentifier] ?? TypeState()
            entry.anchorData = data ?? entry.anchorData
            entry.lastSyncedAt = Date()
            entry.totalRecords += added
            entry.lastError = nil
            entry.dirty = false
            if let lastSampleEnd,
               entry.lastSampleEnd == nil || lastSampleEnd > (entry.lastSampleEnd ?? .distantPast) {
                entry.lastSampleEnd = lastSampleEnd
            }
            state[typeIdentifier] = entry
        }
    }

    // MARK: - Bookkeeping

    func recordError(_ message: String, for typeIdentifier: String) {
        store.mutate { state in
            var entry = state[typeIdentifier] ?? TypeState()
            entry.lastError = message
            state[typeIdentifier] = entry
        }
    }

    func markDirty(_ typeIdentifier: String) {
        store.mutate { state in
            var entry = state[typeIdentifier] ?? TypeState()
            entry.dirty = true
            state[typeIdentifier] = entry
        }
    }

    var dirtyTypes: Set<String> {
        Set(store.value.filter(\.value.dirty).keys)
    }

    func state(for typeIdentifier: String) -> TypeState? {
        store.value[typeIdentifier]
    }

    var all: [String: TypeState] {
        store.value
    }

    /// Metrics that have not produced data in `staleAfter`. The signal to watch:
    /// revoked permissions, background delivery quietly dying after an OS
    /// update, and expired tokens all look like silence, not errors.
    func staleTypes(staleAfter: TimeInterval = 48 * 3600) -> [String] {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        return store.value
            .filter { $0.value.totalRecords > 0 && ($0.value.lastSampleEnd ?? .distantPast) < cutoff }
            .keys
            .sorted()
    }

    /// Rewinds one type so the next sync re-reads it from the backfill start.
    ///
    /// `totalRecords` is zeroed with the anchor: it counts what this device has
    /// delivered, and leaving it standing after a rewind would double-count the
    /// same samples on the way back through.
    func clearAnchor(for typeIdentifier: String) {
        store.mutate { state in
            guard var entry = state[typeIdentifier] else { return }
            entry.anchorData = nil
            entry.totalRecords = 0
            entry.lastSampleEnd = nil
            entry.dirty = true
            state[typeIdentifier] = entry
        }
    }

    func resetAll() {
        store.reset()
        Log.shared.warn("anchors", "All anchors cleared; next sync will re-read from the backfill start date")
    }
}
