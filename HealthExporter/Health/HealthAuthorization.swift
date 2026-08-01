import Foundation
import HealthKit
import UIKit

/// Read-permission handling, including the two behaviours that reliably cause
/// bugs:
///
/// 1. **Read status is deliberately opaque.** `authorizationStatus(for:)` reports
///    *sharing* only. Apple's docs are explicit that when read access is denied,
///    "it simply appears as if there is no data of the requested type." So an
///    empty result can never be reported as a denial — it is indistinguishable
///    from an empty Health database.
/// 2. **You get one prompt per type, ever.** Calling `requestAuthorization`
///    again for already-decided types returns immediately with no UI. The only
///    recovery path is deep-linking the user into Settings.
@MainActor
final class HealthAuthorization: ObservableObject {

    struct Settings: Codable {
        var enabledGroupIDs: Set<String>
        var hasRequested: Bool = false
        var requestedAt: Date?
    }

    @Published private(set) var enabledGroupIDs: Set<String>
    @Published private(set) var hasRequested: Bool
    @Published private(set) var lastRequestError: String?

    private let store: StateStore<Settings>
    let healthStore = HKHealthStore()

    init() {
        let store = StateStore<Settings>(
            filename: "authorization.json",
            fallback: Settings(enabledGroupIDs: MetricCatalog.defaultGroupIDs)
        )
        self.store = store
        self.enabledGroupIDs = store.value.enabledGroupIDs
        self.hasRequested = store.value.hasRequested
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func setGroup(_ id: String, enabled: Bool) {
        if enabled { enabledGroupIDs.insert(id) } else { enabledGroupIDs.remove(id) }
        let snapshot = enabledGroupIDs
        store.mutate { $0.enabledGroupIDs = snapshot }
    }

    func enableAll() {
        enabledGroupIDs = MetricCatalog.allGroupIDs
        let snapshot = enabledGroupIDs
        store.mutate { $0.enabledGroupIDs = snapshot }
    }

    /// Requesting ~170 types in one sheet produces a wall of toggles that is
    /// easy to reject wholesale, so the UI asks group by group and this method
    /// only covers what the user opted into.
    func requestAuthorization() async {
        guard isAvailable else {
            lastRequestError = "HealthKit is not available on this device."
            return
        }
        let types = MetricCatalog.readTypes(groupIDs: enabledGroupIDs)
        guard !types.isEmpty else {
            lastRequestError = "No metric groups selected."
            return
        }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: types)
            hasRequested = true
            lastRequestError = nil
            store.mutate {
                $0.hasRequested = true
                $0.requestedAt = Date()
            }
            Log.shared.info("auth", "Requested read access for \(types.count) types")
        } catch {
            lastRequestError = error.localizedDescription
            Log.shared.error("auth", "Authorization request failed: \(error.localizedDescription)")
        }
    }

    /// The floor HealthKit will serve samples from, regardless of what you ask
    /// for. Used to clamp the backfill start date so the engine doesn't grind
    /// through years of windows that can never return anything.
    var earliestQueryableDate: Date {
        healthStore.earliestPermittedSampleDate()
    }

    /// Deep-link to Settings. `requestAuthorization` will not re-prompt for
    /// types the user has already decided on, so this is the only fix path.
    func openHealthSettings() {
        // Health-specific privacy panes are not reliably addressable; the app's
        // own Settings page is the dependable destination.
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    var enabledSampleTypes: Set<HKSampleType> {
        MetricCatalog.sampleTypes(groupIDs: enabledGroupIDs)
    }
}
