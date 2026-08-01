import Foundation
import UIKit
import UserNotifications

/// The 08:00 morning brief.
///
/// **Why a local notification rather than a push.** A server-side push would let
/// the content be composed at the moment it fires, but it needs an APNs key from
/// the Apple Developer account and a push service alongside the ingest server.
/// A local notification needs neither, and for a single-person app the
/// difference in what actually lands on the lock screen is one thing: freshness.
///
/// **How freshness is handled.** iOS will not run code to compose a local
/// notification at fire time — the content has to be written in advance. So the
/// brief is refreshed and the alert re-scheduled at every opportunity: on
/// launch, on foreground, after any sync, and from the existing background
/// refresh task, which is asked to run in the small hours specifically so the
/// morning's copy is usually written overnight.
///
/// When that fails, the notification still fires with the most recent brief and
/// says which day it describes, so it is never quietly wrong. And tapping it
/// re-fetches immediately — the alert is a nudge, the detail is always live.
@MainActor
final class DailyBriefScheduler: ObservableObject {

    static let notificationIdentifier = "com.lionelchong.HealthExporter.dailyBrief"
    static let categoryIdentifier = "DAILY_BRIEF"

    struct Settings: Codable, Equatable {
        var enabled: Bool = true
        var hour: Int = 8
        var minute: Int = 0
        /// Suppresses the alert on days when nothing moved and nothing broke.
        /// A notification that says "nothing changed" every morning is one
        /// people switch off, and then they miss the day it matters.
        var onlyWhenNotable: Bool = true
    }

    @Published var settings: Settings {
        didSet {
            store.mutate { $0 = settings }
            Task { await reschedule() }
        }
    }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastBrief: DailyBrief?
    @Published private(set) var lastScheduledFor: Date?

    private let store = StateStore<Settings>(filename: "daily-brief.json", fallback: Settings())
    private let center = UNUserNotificationCenter.current()
    private unowned let engine: SyncEngine

    init(engine: SyncEngine) {
        self.engine = engine
        self.settings = store.value
    }

    // MARK: - Authorization

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    /// Asks once. iOS never re-prompts, so a denial can only be undone in
    /// Settings — which is what `openSystemSettings` is for.
    @discardableResult
    func requestAuthorization() async -> Bool {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else {
            return authorizationStatus == .authorized || authorizationStatus == .provisional
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            Log.shared.info("notify", granted ? "Notifications authorized" : "Notifications denied")
            return granted
        } catch {
            Log.shared.error("notify", "Authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Scheduling

    func registerCategory() {
        // No custom actions: the useful interaction is "open the app and show
        // me", which is the default tap. Extra buttons on a once-a-day alert
        // are decoration.
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    /// Fetches the current brief and rewrites tomorrow morning's alert.
    ///
    /// Safe and cheap to call often — it replaces the pending request rather
    /// than adding one, so repeated calls cannot stack up duplicate alarms.
    func refresh() async {
        guard settings.enabled, engine.isSignedIn else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
            return
        }

        let sink = HTTPSink(configuration: engine.settings.sink)
        if case .success(let brief) = await sink.fetchDailyBrief() {
            lastBrief = brief
        }
        await reschedule()
    }

    func reschedule() async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
        lastScheduledFor = nil

        guard settings.enabled, engine.isSignedIn, let brief = lastBrief else { return }
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        if settings.onlyWhenNotable && !brief.worthNotifying {
            Log.shared.debug("notify", "Nothing notable; no alert scheduled for tomorrow")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Morning brief"
        content.body = brief.notificationBody
        content.categoryIdentifier = Self.categoryIdentifier
        content.sound = .default
        content.userInfo = ["as_of": brief.asOf]
        // Says which day the numbers describe. Without it a brief written last
        // night and delivered this morning is indistinguishable from one
        // composed at 08:00, which is the kind of small dishonesty that makes
        // people stop trusting the whole screen.
        content.subtitle = "Through \(brief.asOf)"

        var components = DateComponents()
        components.hour = settings.hour
        components.minute = settings.minute

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: content,
            // Repeating, so the alert survives a stretch where the app never
            // runs in the background. The content goes stale in that case, but
            // a stale nudge that gets you to open the app beats silence.
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )

        do {
            try await center.add(request)
            lastScheduledFor = Calendar.current.nextDate(
                after: Date(),
                matching: components,
                matchingPolicy: .nextTime
            )
            Log.shared.info("notify", "Morning brief scheduled for \(settings.hour):"
                            + String(format: "%02d", settings.minute))
        } catch {
            Log.shared.error("notify", "Could not schedule: \(error.localizedDescription)")
        }
    }
}

/// Routes a notification tap to the Insights tab.
///
/// Separate from the scheduler because `UNUserNotificationCenterDelegate` must
/// be set before the app finishes launching — otherwise a tap that *launched*
/// the app is delivered before anything is listening and is lost, which shows up
/// as "tapping the alert sometimes does nothing".
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == DailyBriefScheduler.notificationIdentifier {
            Task { @MainActor in
                AppServices.shared.openDailyBrief()
            }
        }
        completionHandler()
    }

    /// Shown even with the app in the foreground. Suppressing it would mean the
    /// 08:00 brief silently does not appear on exactly the mornings the app
    /// happens to be open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
