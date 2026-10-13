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
        // Aimed at the small hours when the morning brief needs writing.
        //
        // iOS decides when this actually runs and will not be argued with, but
        // it does honour "not before". Asking for pre-dawn is the difference
        // between the 08:00 alert usually describing this morning and usually
        // describing yesterday evening — a local notification's text has to be
        // written in advance, so this is the only lever there is.
        refresh.earliestBeginDate = min(
            Date(timeIntervalSinceNow: interval),
            BackgroundSync.nextPreDawn()
        )
        submit(refresh)
    }

    /// The next 05:30 local. Early enough to leave iOS a wide window before the
    /// alert fires, late enough that the day's overnight sleep samples exist.
    private static func nextPreDawn() -> Date {
        let calendar = Calendar.current
        var components = DateComponents()
        components.hour = 5
        components.minute = 30
        return calendar.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime)
            ?? Date(timeIntervalSinceNow: 3_600)
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
            // Last, and on both paths: this is the only chance to write the
            // morning alert's text with anything current in it, and it needs
            // the upload above to have landed first.
            await shared.dailyBrief.refresh()
            // The reason this notifier exists. Every other place it runs, the
            // app is open and the Summary tab is already saying sync failed —
            // here nobody is looking, which is exactly when weeks go by.
            await shared.syncFailure.evaluate()
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

    /// Registers the observer queries alone — no delivery round trips — when
    /// the app was launched without a window.
    ///
    /// HealthKit relaunches a terminated app in the background to deliver an
    /// update, and the update goes to whichever `HKObserverQuery` exists by the
    /// time launch finishes. `startObserving` only ran from the SwiftUI `.task`,
    /// which a windowless background launch need not run, so on exactly those
    /// launches no query was there to receive the wake or call its completion
    /// handler — and three of those is how HealthKit decides to stop delivering.
    /// Apple's guidance is to set the queries up in `didFinishLaunching`; this is
    /// the part of `startObserving` cheap enough to run there.
    func registerObserversAtLaunch() {
        guard authorization.isAvailable, authorization.hasRequested else { return }
        registerObservers(for: authorization.enabledSampleTypes)
    }

    /// Idempotent: the same set of types already observed is left alone, so the
    /// launch-time registration and the later `startObserving` do not tear down
    /// and re-create ~130 queries — each of which fires once on creation.
    private func registerObservers(for types: Set<HKSampleType>) {
        let wanted = Set(types.map(\.identifier))
        if wanted == Set(activeObservers.map { $0.objectType?.identifier ?? "" }) { return }

        for query in activeObservers { authorization.healthStore.stop(query) }
        activeObservers.removeAll()

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
        }
    }

    /// Registers observers for every enabled type and asks HealthKit to wake us.
    /// Cheap and safe to call on every launch — re-registering is idempotent, and
    /// it is the only way to recover if delivery was previously switched off.
    func startObserving() async {
        guard authorization.isAvailable else { return }
        let types = authorization.enabledSampleTypes
        registerObservers(for: types)
        guard !types.isEmpty else { return }

        // Registering the queries is local and cheap. *This* is the
        // expensive half, and it used to be a third of this loop: one awaited
        // XPC round trip to `healthd` per type, ~130 of them, one after
        // another — and because this class is `@MainActor`, every one of those
        // suspensions and resumptions happened on the main thread while
        // somebody was trying to scroll.
        //
        // Hoisted out, moved off the actor, and run a few at a time.
        await Self.enableBackgroundDelivery(for: types, store: authorization.healthStore)

        Log.shared.info("observer",
            "Observing \(types.count) type(s) with hourly background delivery")
    }

    /// Turns on hourly background delivery for every type, off the main actor.
    ///
    /// `nonisolated` is the point: `HKHealthStore` does its own synchronisation
    /// and none of this touches actor state, so there is no reason for it to
    /// occupy the main thread.
    ///
    /// Bounded concurrency rather than a task per type. Firing ~130 requests at
    /// `healthd` at once trades a main-thread stall for a daemon queue, which is
    /// not obviously better and is much harder to reason about; a handful in
    /// flight gets nearly all of the win.
    ///
    /// `.hourly` rather than `.immediate`: many types are throttled to hourly
    /// regardless, and requesting immediate delivery across ~170 types is a
    /// good way to be woken constantly for no benefit.
    nonisolated private static func enableBackgroundDelivery(
        for types: Set<HKSampleType>,
        store: HKHealthStore
    ) async {
        let inFlight = 6
        var remaining = Array(types)

        await withTaskGroup(of: Void.self) { group in
            func addNext() {
                guard let type = remaining.popLast() else { return }
                group.addTask {
                    do {
                        try await store.enableBackgroundDelivery(for: type, frequency: .hourly)
                    } catch {
                        Log.shared.warn("observer",
                            "Background delivery refused for \(type.identifier): "
                            + error.localizedDescription)
                    }
                }
            }
            for _ in 0..<min(inFlight, remaining.count) { addNext() }
            while await group.next() != nil { addNext() }
        }
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
