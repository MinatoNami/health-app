import Foundation
import HealthKit
import BackgroundTasks
import UIKit

/// Keeps data flowing without the app being opened.
///
/// Two mechanisms, because neither is sufficient alone:
///
/// * **`HKObserverQuery` + background delivery** — HealthKit wakes the app when
///   data lands. Delivery is throttled (hourly at best for many types) and the
///   wake window is short.
/// * **`BGProcessingTask`** — a longer runway the system grants when convenient,
///   used to actually drain and deliver.
///
/// The observer's job is therefore *only* to record that a type went dirty and
/// return immediately. Apple's contract is strict: if the completion handler
/// isn't called, HealthKit retries with backoff, and after **three** failures it
/// stops sending background updates for that type. That failure is silent and
/// persists until observers are re-registered, which makes it the single most
/// important thing not to get wrong in this file.
@MainActor
final class BackgroundSync {

    static let processingTaskIdentifier = "com.lionelchong.HealthExporter.sync"
    static let refreshTaskIdentifier = "com.lionelchong.HealthExporter.refresh"

    private let authorization: HealthAuthorization
    private let engine: SyncEngine
    private var activeObservers: [HKObserverQuery] = []
    private var didRegisterTasks = false

    init(authorization: HealthAuthorization, engine: SyncEngine) {
        self.authorization = authorization
        self.engine = engine
    }

    // MARK: - BGTaskScheduler

    /// Must run before the app finishes launching, or the system throws when the
    /// task fires.
    func registerTaskHandlers() {
        guard !didRegisterTasks else { return }
        didRegisterTasks = true

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundSync.processingTaskIdentifier,
            using: nil
        ) { task in
            BackgroundSync.handle(task: task, isProcessing: true)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundSync.refreshTaskIdentifier,
            using: nil
        ) { task in
            BackgroundSync.handle(task: task, isProcessing: false)
        }
        Log.shared.debug("bgtask", "Registered background task handlers")
    }

    func scheduleNextRun(after interval: TimeInterval = 3_600) {
        let processing = BGProcessingTaskRequest(identifier: BackgroundSync.processingTaskIdentifier)
        // HealthKit reads need neither, and requiring them only delays runs. The
        // upload step tolerates being offline: batches stay spooled on disk.
        processing.requiresNetworkConnectivity = false
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        submit(processing)

        let refresh = BGAppRefreshTaskRequest(identifier: BackgroundSync.refreshTaskIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        submit(refresh)
    }

    private func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected in the simulator, and when the identifier is missing from
            // BGTaskSchedulerPermittedIdentifiers in Info.plist.
            Log.shared.warn("bgtask",
                "Could not schedule \(request.identifier): \(error.localizedDescription)")
        }
    }

    /// Static and non-isolated: BGTaskScheduler calls its handler from a
    /// non-isolated context, so the hop onto the main actor happens inside.
    private nonisolated static func handle(task: BGTask, isProcessing: Bool) {
        Log.shared.info("bgtask", "Woke for \(task.identifier)")

        // `setTaskCompleted` must be called exactly once: the system treats a
        // missing call as a hang, and a second call as a programming error. The
        // work task and the expiration handler race, so gate both.
        let finished = CompletionGate()

        let work = Task { @MainActor in
            let shared = AppServices.shared
            // Re-arm first: a scheduled task fires at most once, so forgetting
            // this silently ends all future background runs.
            shared.backgroundSync.scheduleNextRun()

            if isProcessing {
                await shared.syncEngine.syncAll(reason: "background processing task")
            } else {
                await shared.syncEngine.syncDirtyTypes()
                await shared.syncEngine.deliverPending()
            }
            if finished.claim() { task.setTaskCompleted(success: true) }
        }

        task.expirationHandler = {
            Log.shared.warn("bgtask",
                "\(task.identifier) expired; anchors preserve partial progress")
            work.cancel()
            if finished.claim() { task.setTaskCompleted(success: false) }
        }
    }

    // MARK: - Observers

    /// Registers observers for every enabled type and asks HealthKit to wake us.
    /// Cheap and safe to call on every launch — re-registering is idempotent, and
    /// it is the only way to recover if delivery was previously switched off.
    func startObserving() async {
        guard authorization.isAvailable else { return }

        for query in activeObservers { authorization.healthStore.stop(query) }
        activeObservers.removeAll()

        let types = authorization.enabledSampleTypes
        guard !types.isEmpty else { return }

        for type in types {
            let identifier = type.identifier
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if let error {
                    Log.shared.error("observer", "\(identifier): \(error.localizedDescription)")
                    // Complete anyway. Withholding the handler is exactly what
                    // gets background delivery disabled after three strikes.
                    completion()
                    return
                }

                // Flag, then return immediately. The flag is persisted, so a wake
                // we cannot service now — locked device, no runway — is picked up
                // by the next background task or app launch rather than lost.
                AnchorStore.shared.markDirty(identifier)
                completion()

                // Request a *coalesced* drain rather than awaiting one here.
                // Observer queries fire once as soon as they're executed, so
                // awaiting directly means ~130 concurrent drains at launch.
                Task { @MainActor in
                    AppServices.shared.syncEngine.requestDirtyDrain()
                }
            }
            authorization.healthStore.execute(query)
            activeObservers.append(query)

            // `.hourly` rather than `.immediate`: many types are throttled to
            // hourly regardless, and requesting immediate delivery across ~170
            // types is a good way to be woken constantly for no benefit.
            do {
                try await authorization.healthStore.enableBackgroundDelivery(
                    for: type, frequency: .hourly
                )
            } catch {
                Log.shared.warn("observer",
                    "Background delivery refused for \(identifier): \(error.localizedDescription)")
            }
        }

        Log.shared.info("observer",
            "Observing \(types.count) type(s) with hourly background delivery")
    }

    func stopObserving() async {
        for query in activeObservers { authorization.healthStore.stop(query) }
        activeObservers.removeAll()
        try? await authorization.healthStore.disableAllBackgroundDelivery()
        Log.shared.info("observer", "Stopped all observers and background delivery")
    }
}

/// One-shot latch, so two racing callers can't both signal completion.
final class CompletionGate {
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
