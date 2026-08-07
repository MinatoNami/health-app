import Foundation
import SwiftUI
import UserNotifications

/// Single owner of the long-lived objects.
///
/// A shared reference is needed because `BGTaskScheduler` handlers are static
/// entry points invoked by the system long after any view has gone away — they
/// need a way back to the live engine rather than constructing a second one with
/// its own anchors.
/// What the app is doing between the first frame and a usable interface.
///
/// Every step here is real work with a real cost — nothing is padded to make the
/// bar move. The bar is honest about how many steps there are, so it advances in
/// thirds rather than pretending to a precision it does not have.
///
/// Two rules keep it from becoming the problem it exists to solve. It never
/// waits for the full sync, which takes minutes on a first run and is not needed
/// for the app to be useful; and a watchdog finishes it regardless, so a stalled
/// network or an unresponsive HealthKit can never leave somebody staring at a
/// progress bar that will not move.
@MainActor
final class BootProgress: ObservableObject {
    struct Step: Identifiable, Equatable {
        let id: String
        let label: String
    }

    /// One step, because there is now only one thing the interface waits on.
    /// Anything else that appeared here would be a bar padded to look busy.
    static let steps: [Step] = [
        Step(id: "cache", label: "Loading your latest figures")
    ]

    /// How long the app is allowed to take before it owes the user an
    /// explanation. Under this, showing a progress view is worse than showing
    /// nothing — the screen flashes something the eye cannot read, and the app
    /// feels less responsive for having explained itself.
    private static let grace: Duration = .milliseconds(250)
    /// Once it *has* appeared, it stays this long. A bar that appears and
    /// vanishes inside a frame reads as a glitch.
    private static let minimumOnScreen: Duration = .milliseconds(350)
    /// Dismissed after this whatever is outstanding. Boot is allowed to be
    /// slow; it is not allowed to be indefinite.
    private static let watchdog: Duration = .seconds(4)

    @Published private(set) var completed: Set<String> = []
    @Published private(set) var label: String = "Starting up"
    @Published private(set) var isFinished = false
    /// Whether the boot screen has earned its place on screen. False for the
    /// first quarter-second, which is the common case now that the interface
    /// opens on cached figures rather than on a network round trip.
    @Published private(set) var isVisible = false

    private var appearedAt: ContinuousClock.Instant?
    private var didStart = false
    private var watchdogTask: Task<Void, Never>?

    var fraction: Double {
        guard !Self.steps.isEmpty else { return 1 }
        return Double(completed.count) / Double(Self.steps.count)
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        Task { [weak self] in
            try? await Task.sleep(for: Self.grace)
            guard let self, !self.isFinished else { return }
            self.appearedAt = ContinuousClock.now
            self.isVisible = true
        }

        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: Self.watchdog)
            guard let self, !self.isFinished else { return }
            Log.shared.warn("boot", "Boot watchdog fired; showing the interface anyway")
            self.finish()
        }
    }

    /// Runs one step, marking it complete however it ends. A step that throws or
    /// times out still has to advance the bar — the alternative is a bar that
    /// stops at two thirds because the network was down.
    func step<T>(_ id: String, _ work: () async -> T) async -> T {
        if let match = Self.steps.first(where: { $0.id == id }) { label = match.label }
        let result = await work()
        completed.insert(id)
        return result
    }

    /// Marks a step as not applicable — no Health access yet, not signed in.
    /// It still counts as done, because there is genuinely nothing to wait for.
    func skip(_ id: String) {
        completed.insert(id)
    }

    func finish() {
        guard !isFinished else { return }
        watchdogTask?.cancel()
        watchdogTask = nil

        // Never appeared, so there is nothing to hold on screen — the interface
        // is simply ready, and this dismisses without ever having been seen.
        guard let appearedAt else {
            isFinished = true
            return
        }

        let shown = ContinuousClock.now - appearedAt
        guard shown >= Self.minimumOnScreen else {
            Task { [weak self] in
                try? await Task.sleep(for: Self.minimumOnScreen - shown)
                self?.isFinished = true
            }
            return
        }
        isFinished = true
    }
}

@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    /// Owned here because boot spans the app, not any one screen.
    let boot = BootProgress()

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
    /// Set while the launch chores are in flight, so a second `.task` — a tab
    /// switch, a scene re-activation — does not start them again.
    private var launchWork: Task<Void, Never>?
    /// The in-flight figure refresh, so returning to the foreground twice in a
    /// second does not start two of them.
    private var refreshWork: Task<Void, Never>?
    private var refreshedAt: Date?

    /// How old the on-screen figures may be before coming back to the app is
    /// worth a refresh. Below this, the cached numbers are the same numbers.
    private static let staleAfter: TimeInterval = 5 * 60

    func onLaunch() async {
        guard launchWork == nil else { return }
        boot.start()

        // The only thing the interface truly waits on: last time's figures, off
        // a local disk. Everything the first screen draws comes from here, so
        // the app opens on real content instead of on placeholder text that a
        // network round trip will eventually replace.
        await boot.step("cache") {
            await syncEngine.restoreCachedViews()
        }

        // The interface is ready. Not "ready except for the numbers" — ready.
        // Everything below runs behind it, and each piece updates the screen
        // when it lands.
        boot.finish()

        // Refreshing the figures is deliberately *not* awaited above. Cached
        // numbers with an "updated 2 hours ago" line beat a spinner over an
        // empty screen, and on a bad connection they beat it by a minute.
        refreshWork = Task { [weak self] in
            guard let self, self.syncEngine.isSignedIn else { return }
            await self.syncEngine.refreshSnapshot()
            await self.syncEngine.refreshTrends()
            self.refreshedAt = Date()
        }

        await dailyBrief.refreshAuthorizationStatus()
        guard authorization.hasRequested else { return }

        // Registering ~130 observers takes real time on a first run and the
        // interface does not depend on it — it is what keeps background delivery
        // alive, which matters between launches rather than during one.
        //
        // The sync behind it used to be awaited before the first screen could
        // finish appearing: the heaviest work in the app, scheduled at the exact
        // moment the user is trying to touch it. Background priority so the UI
        // wins every scheduling contest against it, and the task is retained so a
        // second call joins the one already running rather than starting a
        // second sync.
        launchWork = Task(priority: .background) { [weak self] in
            guard let self else { return }
            await self.backgroundSync.startObserving()
            self.backgroundSync.scheduleNextRun()
            await self.syncEngine.syncAll(reason: "app launch")

            // Ask here, not only from the Settings toggle. The setting ships
            // enabled, so its `didSet` never fires on a fresh install — leaving
            // permission unrequested and the alert silently never arriving,
            // which looks exactly like a feature that does not work. Gated on
            // Health access already being granted, so it is never the first
            // thing a new install asks for.
            if self.dailyBrief.settings.enabled,
               self.dailyBrief.authorizationStatus == .notDetermined {
                await self.dailyBrief.requestAuthorization()
            }
            // After the sync, so the brief describes what was just uploaded
            // rather than the state before it.
            await self.dailyBrief.refresh()
            self.launchWork = nil
        }
    }

    /// Coming back to the app, which is not the same as launching it.
    ///
    /// The old behaviour was nothing at all: `.task` runs once for the lifetime
    /// of the view, so an app resumed after two days showed two-day-old figures
    /// until something else happened to refresh them. The new behaviour is not
    /// "run launch again" either — re-registering observers and re-syncing every
    /// time somebody glances at the app is how a phone gets warm in a pocket.
    ///
    /// Just the figures, and only when they are old enough to be wrong.
    func onForeground() {
        guard launchWork != nil || refreshWork != nil || refreshedAt != nil else {
            // Never launched properly — let `.task` do its job instead.
            return
        }
        guard refreshWork == nil else { return }
        if let refreshedAt, Date().timeIntervalSince(refreshedAt) < Self.staleAfter { return }
        guard syncEngine.isSignedIn else { return }

        refreshWork = Task { [weak self] in
            guard let self else { return }
            await self.syncEngine.refreshSnapshot()
            await self.syncEngine.refreshTrends()
            self.refreshedAt = Date()
            self.refreshWork = nil
        }
        // Anything the observers flagged while the app was away. Already
        // debounced and serialised by the engine.
        syncEngine.requestDirtyDrain()
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
