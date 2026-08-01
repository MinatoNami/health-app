import Foundation
import SwiftUI
import UserNotifications

/// Single owner of the long-lived objects.
///
/// A shared reference is needed because `BGTaskScheduler` handlers are static
/// entry points invoked by the system long after any view has gone away — they
/// need a way back to the live engine rather than constructing a second one with
/// its own anchors.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let authorization: HealthAuthorization
    let syncEngine: SyncEngine
    let backgroundSync: BackgroundSync
    let dailyBrief: DailyBriefScheduler

    /// Which tab is showing. Owned here rather than by `RootView` so a
    /// notification tap can change it — the tap arrives at the app delegate,
    /// long before any view is in a position to react.
    @Published var selectedTab: Tab = .status
    /// Set when Insights was opened from the morning alert, so it can lead with
    /// the brief rather than the general screen.
    @Published var showBriefOnOpen = false

    enum Tab: Hashable {
        case status, insights, metrics, server, settings
    }

    init() {
        let auth = HealthAuthorization()
        let engine = SyncEngine(authorization: auth)
        self.authorization = auth
        self.syncEngine = engine
        self.backgroundSync = BackgroundSync(authorization: auth, engine: engine)
        self.dailyBrief = DailyBriefScheduler(engine: engine)
    }

    /// Must run inside `didFinishLaunchingWithOptions`. `BGTaskScheduler.register`
    /// throws if it happens after launch completes, which is earlier than any
    /// SwiftUI `.task` — hence the app delegate. The notification delegate has
    /// the same constraint for a different reason: a tap that *launched* the app
    /// is delivered immediately, and is lost if nothing is listening yet.
    func bootstrap() {
        backgroundSync.registerTaskHandlers()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        dailyBrief.registerCategory()
    }

    /// Called when the app becomes active. Re-registering observers every launch
    /// is deliberate: if HealthKit previously stopped background delivery, this
    /// is the only thing that brings it back.
    func onLaunch() async {
        await dailyBrief.refreshAuthorizationStatus()
        guard authorization.hasRequested else { return }
        await backgroundSync.startObserving()
        backgroundSync.scheduleNextRun()
        await syncEngine.syncAll(reason: "app launch")

        // Ask here, not only from the Settings toggle. The setting ships
        // enabled, so its `didSet` never fires on a fresh install — leaving
        // permission unrequested and the alert silently never arriving, which
        // looks exactly like a feature that does not work. Gated on Health
        // access already being granted, so it is never the first thing a new
        // install asks for.
        if dailyBrief.settings.enabled && dailyBrief.authorizationStatus == .notDetermined {
            await dailyBrief.requestAuthorization()
        }
        // After the sync, so the brief describes what was just uploaded rather
        // than the state before it.
        await dailyBrief.refresh()
    }

    /// A tap on the morning alert.
    func openDailyBrief() {
        selectedTab = .insights
        showBriefOnOpen = true
        Log.shared.info("notify", "Opened from the morning brief")
        Task {
            // The alert's text may have been written last night; this is not.
            await syncEngine.refreshSnapshot()
            await dailyBrief.refresh()
        }
    }
}
