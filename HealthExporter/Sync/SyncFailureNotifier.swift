import Foundation
import UserNotifications

/// Says out loud that nothing is uploading.
///
/// The whole system is built against silence — the coverage report, the
/// freshness check, metrics reported as *not syncing* rather than as zero. All
/// of that catches data that stopped arriving *at the server*. None of it
/// catches the phone failing to send in the first place, because a server that
/// is never contacted has nothing to notice.
///
/// `SyncEngine` does notice. A revoked token trips the upload circuit breaker
/// after three rejections and sets `phase` to say so. But `phase` is a
/// `@Published` property on a screen, and the entire point of background sync
/// is that nobody is looking at the screen. Worse, `isSignedIn` means "a token
/// is in the Keychain", which a *revoked* token still satisfies — so the morning
/// brief kept scheduling, kept firing, and kept showing the last figures it
/// managed to fetch. The only tell was its `Through <date>` subtitle going
/// quietly stale.
///
/// So this is the one alert about the pipe rather than what flows through it.
///
/// **It stays quiet unless uploading was asked for.** No token, uploading
/// switched off, no server configured — those are choices, and alerting about a
/// choice is how an alert gets muted before the day it matters. Same reasoning
/// that exempts self-reported metrics from the server's freshness check.
@MainActor
final class SyncFailureNotifier: ObservableObject {

    /// `nonisolated` for the same reason as the brief's: `NotificationRouter`
    /// compares against it from a delegate callback made off the main actor,
    /// and an immutable `String` has nothing for isolation to protect.
    nonisolated static let notificationIdentifier = "com.lionelchong.HealthExporter.syncStalled"

    /// How long a queue may sit undelivered before it is worth an alert.
    ///
    /// Three days, not one. Uploads legitimately go quiet for a weekend away
    /// from Wi-Fi with Low Power Mode on, and an alert that fires on every such
    /// stretch teaches you to swipe it away. Three days is longer than any
    /// ordinary gap and far shorter than the five weeks of missing sleep data
    /// that motivated the freshness work.
    static let stallAfterDays = 3

    /// Minimum gap between two alerts about the same fault. The condition is
    /// re-evaluated constantly — every launch, foreground, sync and background
    /// run — and without this a broken token would notify on each one.
    static let renotifyAfterDays = 3

    /// What is wrong, in the order it is worth saying.
    enum Fault: String, Codable {
        /// The server rejected this device's credential. Nothing will upload
        /// again until somebody signs in, so this is worth saying immediately
        /// rather than after a stall window.
        case tokenRejected
        /// Batches are queued and none has been accepted in a while.
        case stalled

        var body: String {
            switch self {
            case .tokenRejected:
                return "The server rejected this iPhone's sign-in. Nothing has uploaded since. "
                    + "Open Settings → Account and sign in again."
            case .stalled:
                return "Health data has been queuing on this iPhone without reaching the server."
            }
        }
    }

    struct State: Codable {
        var lastNotifiedAt: Date?
        var lastFault: Fault?
    }

    /// Everything the decision depends on, lifted out of `SyncEngine`.
    ///
    /// Separated so the rule can be read — and tested — without standing up a
    /// sync engine, a HealthKit store and an authorization object to ask it four
    /// questions. The rule is the part worth being sure about; the plumbing that
    /// reads these five values off the engine is not.
    struct Conditions {
        var uploadEnabled: Bool
        var serverUsable: Bool
        var isSignedIn: Bool
        var tokenRejected: Bool
        var pendingBatches: Int
        /// The last time anything actually got through, falling back to the last
        /// completed sync so a fresh install that has never delivered still has
        /// a clock to measure against.
        var lastProgressAt: Date?
    }

    /// The rule itself. Pure: same inputs, same answer, no clock of its own.
    static func fault(for conditions: Conditions, now: Date) -> Fault? {
        // Uploading not asked for is not a fault. Alerting about a deliberate
        // choice is how an alert gets switched off before the day it matters.
        guard conditions.uploadEnabled,
              conditions.serverUsable,
              conditions.isSignedIn else { return nil }

        // Ahead of the stall window: nothing will upload again until somebody
        // signs in, so waiting three days to mention it helps nobody.
        if conditions.tokenRejected { return .tokenRejected }

        // An empty queue means the last run delivered everything it read, however
        // long ago that was.
        guard conditions.pendingBatches > 0 else { return nil }
        guard let since = conditions.lastProgressAt else { return nil }

        let stalled = now.timeIntervalSince(since) > Double(stallAfterDays) * 86_400
        return stalled ? .stalled : nil
    }

    private let store = StateStore<State>(filename: "sync-alert.json", fallback: State())
    private let center = UNUserNotificationCenter.current()
    private unowned let engine: SyncEngine

    init(engine: SyncEngine) {
        self.engine = engine
    }

    // MARK: - Evaluation

    /// Decides whether the current state deserves an alert, and posts one.
    ///
    /// Cheap and safe to call often — a directory listing for the queue size,
    /// then already-published state. Called wherever the brief is refreshed,
    /// which is every point at which the app learns anything new.
    func evaluate() async {
        // Read the queue size here rather than trusting the published one. That
        // is refreshed by a fire-and-forget task and starts at 0, so on a cold
        // background launch — the one time nobody is looking and this alert
        // matters — it usually still read 0, which counted as "recovered" and
        // withdrew a warning that was still true.
        await engine.refreshCountsNow()
        guard let fault = currentFault() else {
            // Recovered. Withdraw a warning that is no longer true rather than
            // leaving it on the lock screen contradicting a working sync.
            await clear()
            return
        }

        let state = store.value
        // A *different* fault is news even inside the quiet window: "queuing"
        // becoming "your token was rejected" changes what to do about it.
        if state.lastFault == fault, let last = state.lastNotifiedAt,
           Date().timeIntervalSince(last) < Double(Self.renotifyAfterDays) * 86_400 {
            return
        }

        await post(fault)
    }

    /// Reads the five things the rule needs off the engine.
    private var conditions: Conditions {
        var rejected = false
        if case .failed(let message) = engine.phase {
            rejected = message.contains("rejected the token")
        }
        return Conditions(
            uploadEnabled: engine.settings.sink.enabled,
            serverUsable: engine.settings.sink.isUsable,
            isSignedIn: engine.isSignedIn,
            tokenRejected: rejected,
            pendingBatches: engine.pendingBatches,
            lastProgressAt: engine.settings.lastDeliveryAt ?? engine.settings.lastFullSyncAt
        )
    }

    /// The fault worth reporting, or nil if uploading is fine or not asked for.
    private func currentFault() -> Fault? {
        Self.fault(for: conditions, now: Date())
    }

    // MARK: - Posting

    private func post(_ fault: Fault) async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            Log.shared.debug("notify", "Sync alert suppressed: notifications not authorized")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Health Exporter isn't syncing"
        content.body = fault.body
        content.categoryIdentifier = DailyBriefScheduler.categoryIdentifier
        content.sound = .default
        if engine.pendingBatches > 0 {
            content.subtitle = "\(engine.pendingBatches) batch"
                + (engine.pendingBatches == 1 ? "" : "es") + " waiting to upload"
        }

        // No trigger: deliver now. Unlike the brief, this is not an alarm set
        // for a time of day — it is the app reporting something it has just
        // worked out, and the useful moment is this one.
        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            store.mutate {
                $0.lastNotifiedAt = Date()
                $0.lastFault = fault
            }
            Log.shared.warn("notify", "Alerted: sync \(fault.rawValue)")
        } catch {
            Log.shared.error("notify", "Could not post sync alert: \(error.localizedDescription)")
        }
    }

    /// Drops the warning and forgets it was sent, so a fault that returns after
    /// a genuine recovery alerts again rather than being swallowed by the quiet
    /// window from last time.
    func clear() async {
        guard store.value.lastFault != nil else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
        store.mutate {
            $0.lastNotifiedAt = nil
            $0.lastFault = nil
        }
        Log.shared.info("notify", "Sync recovered; warning withdrawn")
    }
}
