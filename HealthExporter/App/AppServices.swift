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
    /// The other local alert: not about the numbers, about whether they are
    /// getting anywhere. See `SyncFailureNotifier` for why that needs saying.
    let syncFailure: SyncFailureNotifier

    /// Which tab is showing. Owned here rather than by `RootView` so a
    /// notification tap can change it — the tap arrives at the app delegate,
    /// long before any view is in a position to react.
    @Published var selectedTab: Tab = .today
    /// Whether the chat history drawer is out.
    ///
    /// Here rather than inside `InsightsView` because the drawer has to cover
    /// the tab bar, and the tab bar is drawn by the `TabView` *above* whatever
    /// a tab's own view puts on screen. Owned at the root, it slides over
    /// everything; owned in the tab, it slid underneath the one control that
    /// stayed bright.
    @Published var showingChatHistory = false
    /// Set when Insights was opened from the morning alert, so it can lead with
    /// the brief rather than the general screen.
    @Published var showBriefOnOpen = false

    /// Whether first-run onboarding still has to happen.
    ///
    /// Persisted rather than derived from `authorization.hasRequested`, because
    /// the two are different questions: someone who read the intro and chose
    /// "Not now" has been onboarded and has not granted anything, and showing
    /// them the same three promises on every launch until they relent is how an
    /// intro screen becomes a nag.
    @Published private(set) var needsOnboarding: Bool

    private struct FirstRun: Codable { var completed = false }
    private let firstRunStore = StateStore<FirstRun>(
        filename: "first-run.json", fallback: FirstRun()
    )

    /// Finishes onboarding, whichever way it ended.
    func completeOnboarding() {
        needsOnboarding = false
        firstRunStore.mutate { $0.completed = true }
        Log.shared.info("app", "Onboarding completed")
    }

    /// Why the configured server could not be reached at startup, if it could
    /// not. `RootView` puts this in front of everything as a blocking alert.
    ///
    /// Deliberately narrow. It is set once, at launch, and only when the app is
    /// actually configured to talk to a server — a phone that has never been
    /// signed in has nothing to be unreachable. The rest of the app keeps its
    /// own behaviour on a failed request: the last figures stay on screen with
    /// a line saying they are stale, because a snapshot from yesterday is worth
    /// more than a blank page.
    /// What went wrong reaching the server at startup, if anything.
    ///
    /// Carries its own title because "Can't reach the server" is only true for
    /// one of the ways this fails. A 404 means the machine answered and does
    /// not have the endpoint — usually an older build still deployed — and
    /// saying it is unreachable sends someone to check their network when the
    /// fix is a redeploy.
    struct ServerProblem: Equatable {
        var title: String
        var detail: String
    }
    @Published var startupServerProblem: ServerProblem?
    /// True while the startup probe is in flight, so the alert's Retry button
    /// can show that something is happening.
    @Published var isCheckingServer = false

    enum Tab: Hashable {
        /// Four, not five. Metrics, Server and Settings all answered "is the
        /// machine working", and three of five tab slots is too much of the
        /// cheapest-to-reach real estate in the app to spend on plumbing. They
        /// live under `data` now.
        case today, insights, trends, data
    }

    init() {
        let auth = HealthAuthorization()
        let engine = SyncEngine(authorization: auth)
        self.authorization = auth
        self.syncEngine = engine
        self.backgroundSync = BackgroundSync(authorization: auth, engine: engine)
        LaunchTrace.mark("init-start")
        self.dailyBrief = DailyBriefScheduler(engine: engine)
        self.syncFailure = SyncFailureNotifier(engine: engine)
        // An install that already granted Health access predates this screen;
        // it has effectively been onboarded and must not be sent back through.
        var pending = !firstRunStore.value.completed && !auth.hasRequested
        #if DEBUG
        // Onboarding is a once-per-install screen, which makes it the one flow
        // a UI test cannot reach twice — and the flag that hides it is exactly
        // the thing likeliest to break. DEBUG only, so it cannot ship.
        if ProcessInfo.processInfo.arguments.contains("-resetFirstRun") {
            firstRunStore.mutate { $0.completed = false }
            pending = true
        }
        #endif
        self.needsOnboarding = pending
        LaunchTrace.mark("init-done")
    }

    /// Must run inside `didFinishLaunchingWithOptions`. `BGTaskScheduler.register`
    /// throws if it happens after launch completes, which is earlier than any
    /// SwiftUI `.task` — hence the app delegate. The notification delegate has
    /// the same constraint for a different reason: a tap that *launched* the app
    /// is delivered immediately, and is lost if nothing is listening yet.
    func bootstrap() {
        LaunchTrace.mark("bootstrap-start")
        defer { LaunchTrace.mark("bootstrap-done") }
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
        LaunchTrace.mark("onLaunch")
        await boot.step("cache") {
            await LaunchTrace.measure("restore-cache") {
                await syncEngine.restoreCachedViews()
            }
        }

        // The interface is ready. Not "ready except for the numbers" — ready.
        // Everything below runs behind it, and each piece updates the screen
        // when it lands.
        boot.finish()
        LaunchTrace.mark("interface-ready")

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

        // Concurrently, not before. This is a network round trip with a 15s
        // timeout, and it used to sit between the interface being ready and the
        // work that keeps the app alive — so a phone whose server was asleep
        // waited the full timeout before a single HealthKit observer was
        // registered. Nothing below depends on its result.
        Task { [weak self] in await self?.checkServerReachable() }

        guard authorization.hasRequested else {
            LaunchTrace.summarise()
            return
        }

        // Registering ~130 observers takes real time on a first run and the
        // interface does not depend on it — it is what keeps background delivery
        // alive, which matters between launches rather than during one.
        //
        // The sync behind it used to be awaited before the first screen could
        // finish appearing: the heaviest work in the app, scheduled at the exact
        // moment the user is trying to touch it. The task is retained so a
        // second call joins the one already running rather than starting a
        // second sync.
        //
        // `priority: .background` buys less than it looks like it does, and the
        // comment that used to sit here claimed otherwise. `SyncEngine` and
        // `BackgroundSync` are both `@MainActor`, so every call below hops to
        // the main actor and runs *there* whatever this task's priority is.
        // Priority orders the queue; it does not choose the thread. Getting
        // this work genuinely off the main thread means de-isolating it, which
        // is a bigger change than a priority argument.
        launchWork = Task(priority: .background) { [weak self] in
            guard let self else { return }
            await LaunchTrace.measure("observers") {
                await self.backgroundSync.startObserving()
            }
            self.backgroundSync.scheduleNextRun()
            await LaunchTrace.measure("first-sync") {
                await self.syncEngine.syncAll(reason: "app launch")
            }

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
            // Last, so it judges the state the sync just left behind rather
            // than the one it started from.
            await self.syncFailure.evaluate()
            self.launchWork = nil
            LaunchTrace.summarise()
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

    // MARK: - Server reachability

    /// Proves the configured server answers before the app settles into using
    /// it, and reports it in front of everything if it does not.
    ///
    /// `probe()` is the same round trip behind Test Connection: it checks the
    /// URL, TLS and the token in one authenticated request and ships no health
    /// data. Doing it at launch means a revoked token or a server that is down
    /// is stated plainly, once, rather than discovered later from a queue that
    /// silently stopped draining.
    ///
    /// **Nothing here is a fault when uploading was never set up.** No token,
    /// no server, uploading switched off — those are configuration states with
    /// their own screens, and putting a modal error over a phone that is
    /// working exactly as configured would be wrong.
    func checkServerReachable() async {
        guard syncEngine.settings.sink.isUsable else {
            startupServerProblem = nil
            return
        }
        isCheckingServer = true
        defer { isCheckingServer = false }

        switch await HTTPSink(configuration: syncEngine.settings.sink).probe() {
        case .success(let message):
            startupServerProblem = nil
            Log.shared.info("sink", "Startup check: \(message)")
        case .failure(let error):
            let detail = error.localizedDescription
            // A refused credential is not an unreachable server, and treating
            // it as one says something false in a modal: the machine answered,
            // it just would not accept this phone. It is also not worth
            // blocking the app for — the cached figures are still readable and
            // the fix is a sign-in, not a retry — so it goes to the Today
            // banner instead, where it arrives with a button that helps.
            if case SinkError.unauthorized = error {
                startupServerProblem = nil
                syncEngine.reportCredentialRejected()
                Log.shared.error("sink", "Startup check: credential rejected")
                return
            }
            // A status code means the server answered. Nearly always a stale
            // deployment: /v1/health/ping arrived with the auth endpoints, so a
            // build older than those 404s every probe while looking perfectly
            // healthy on /healthz.
            if case SinkError.permanent(let status, _) = error {
                startupServerProblem = ServerProblem(
                    title: "The server answered, but not with this",
                    detail: status == 404
                        ? "HTTP 404 for /v1/health/ping. The address is right and something is listening, "
                          + "but it does not have the endpoints this app needs — usually an older build "
                          + "still deployed. Redeploying the server is the fix."
                        : "The server returned HTTP \(status)."
                )
                Log.shared.error("sink", "Startup check: server answered \(status)")
                return
            }
            startupServerProblem = ServerProblem(
                title: "Can't reach the server", detail: detail
            )
            Log.shared.error("sink", "Startup check failed: \(detail)")
        }
    }

    /// Quits.
    ///
    /// iOS has no supported way to do this — the Human Interface Guidelines say
    /// an app should never terminate itself, and App Store Review Guideline
    /// 2.5.4 treats a programmatic quit as a defect, because to the person
    /// holding the phone it is indistinguishable from a crash. `exit(0)` is
    /// what there is.
    ///
    /// It is suspended first so the OS captures a normal-looking snapshot and
    /// the app animates away rather than vanishing mid-frame.
    func closeApp() {
        Log.shared.warn("app", "Closing at the user's request: server unreachable")
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
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
