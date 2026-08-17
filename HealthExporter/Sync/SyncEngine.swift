import Foundation
import HealthKit
import UIKit

/// Orchestrates read → normalize → spool → deliver.
///
/// Design notes worth keeping in mind when changing this file:
///
/// * Paged anchored queries do both the historical backfill *and* incremental
///   sync. Starting from a nil anchor walks the entire store in insertion order,
///   which produces the history and leaves the anchor correctly positioned. One
///   mechanism, no cutover, no possibility of a gap between the two.
/// * The anchor is persisted only after the page has been written to the spool.
/// * Records older than `backfillStart` are read but not emitted, so the anchor
///   still advances over ancient data without paying to normalize and ship it.
@MainActor
final class SyncEngine: ObservableObject {

    enum Phase: Equatable {
        case idle
        case waitingForUnlock
        case syncing(metric: String, progress: Int, total: Int)
        case delivering(remaining: Int)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .syncing, .delivering: return true
            case .idle, .failed, .waitingForUnlock: return false
            }
        }
    }

    struct Settings: Codable {
        /// History cutoff. Defaulting to everything is tempting but a decade of
        /// per-second heart-rate data is a slow first run for little benefit.
        var backfillStartDate: Date = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()
        var pageSize: Int = 2_000
        /// Days of daily statistics to re-emit each run. Statistic IDs are
        /// deterministic, so overlap is a harmless upsert and covers late-arriving
        /// samples that change a past day's total.
        ///
        /// 90 rather than 7 because these rollups are the *only* deduplicated
        /// totals the server ever sees. iPhone and Watch both write step counts,
        /// so a day without a rollup can only be estimated by summing raw
        /// samples — which measures ~1.9x high, and up to 3.5x. Every extra day
        /// here is a day the dashboard can report as fact instead of an
        /// estimate. The cost is one statistics query per metric per run.
        var statisticsLookbackDays: Int = 90
        var sink = SinkConfiguration()
        var lastFullSyncAt: Date?
    }

    /// Result of the last manual Test Connection.
    enum ConnectionTest: Equatable {
        case untested
        case running
        case succeeded(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastSummary: String?
    @Published private(set) var pendingBatches: Int = 0
    @Published private(set) var connectionTest: ConnectionTest = .untested
    @Published var settings: Settings {
        didSet { settingsStore.mutate { $0 = settings } }
    }

    /// Lives in the Keychain rather than in `settings`, so it is deliberately
    /// not part of the persisted struct. Exposed here so the settings screen
    /// has something bindable.
    var bearerToken: String {
        get { Keychain.shared.bearerToken }
        set {
            objectWillChange.send()
            Keychain.shared.bearerToken = newValue
            // A new token invalidates whatever the last test proved.
            connectionTest = .untested
        }
    }

    private let settingsStore = StateStore<Settings>(filename: "sync-settings.json", fallback: Settings())
    private let authorization: HealthAuthorization
    private let reader: HealthReader

    /// Every entry point funnels through this gate. Sync **must** be serialized:
    /// `HKObserverQuery` fires once immediately when executed, so registering
    /// observers for ~130 types kicks off ~130 simultaneous drain requests. Run
    /// concurrently, they re-read the same types from the same stale anchor,
    /// write duplicate batches, clobber each other's anchors, and exhaust memory.
    private var isSyncing = false
    /// Set when a request arrives mid-run. Coalesces a burst into exactly one
    /// follow-up pass instead of dropping the requests or running them in
    /// parallel.
    private var rerunRequested = false
    private var debounceTask: Task<Void, Never>?

    /// When the last progress update was published, for the throttle below.
    private var lastPhasePublish = DispatchTime.now()

    /// Minimum gap between two *progress* updates.
    ///
    /// `phase` is `@Published` on an object seven views observe, and
    /// `ObservableObject` has no per-property tracking: every assignment
    /// invalidates all of them, re-evaluating bodies that draw charts and read
    /// disk-backed state. A full sync assigns it once per type — around 130
    /// times — and delivery once per batch. Nobody can read 130 updates a
    /// second, so the UI is given five and the main thread keeps the rest.
    private static let progressPublishInterval: Double = 0.2

    /// The only way `phase` is set for progress. Terminal states go through it
    /// too and are never throttled — a swallowed `.idle` leaves a spinner
    /// turning over a sync that finished, which is worse than a coarse progress
    /// readout.
    private func report(_ next: Phase) {
        guard next != phase else { return }

        let sameKind: Bool
        switch (phase, next) {
        case (.syncing, .syncing), (.delivering, .delivering): sameKind = true
        default: sameKind = false
        }

        let now = DispatchTime.now()
        if sameKind {
            let elapsed = Double(now.uptimeNanoseconds - lastPhasePublish.uptimeNanoseconds)
                / 1_000_000_000
            guard elapsed >= Self.progressPublishInterval else { return }
        }
        lastPhasePublish = now
        phase = next
    }

    init(authorization: HealthAuthorization) {
        self.authorization = authorization
        self.reader = HealthReader(healthStore: authorization.healthStore)
        self.settings = settingsStore.value
        // Not `Outbox.shared.pendingCount`: that is a directory listing, and an
        // initialiser on the launch path is the worst place to do one. It is
        // filled in by `refreshCounts()` a moment later, off the main thread.
        self.pendingBatches = 0
        migrateSupersededPin()
        migrateStatisticsLookback()
    }

    /// Existing installs persisted the old 7-day default, and a stored value
    /// wins over a new one. Without this the change would only reach fresh
    /// installs, leaving the dashboard estimating totals it could report
    /// exactly. Only moves the old default — a deliberate choice is left alone.
    private func migrateStatisticsLookback() {
        guard settings.statisticsLookbackDays == 7 else { return }
        settings.statisticsLookbackDays = 90
        Log.shared.info("sync", "Raised statistics lookback to 90 days for deduplicated daily totals")
    }

    /// Moves a stored pin forward when the server certificate has been rotated,
    /// and now also clears it when the server has stopped needing one at all.
    ///
    /// The persisted value wins over `defaultPin`, so without this a rotation
    /// would strand every existing install on a pin that no longer matches —
    /// visible only as uploads that silently stop. `defaultPin` is empty since
    /// the server moved to a Let's Encrypt certificate, so for an install still
    /// carrying the self-signed fingerprint this now means "stop pinning and
    /// validate normally", which is the correct outcome rather than a
    /// workaround for one.
    ///
    /// A pin somebody typed themselves is left alone: only the fingerprints
    /// this app has actually shipped are recognised here.
    private func migrateSupersededPin() {
        let stored = CertificatePinner.normalize(settings.sink.pinnedCertificateSHA256)
        guard SinkConfiguration.supersededPins.contains(stored) else { return }
        settings.sink.pinnedCertificateSHA256 = SinkConfiguration.defaultPin
        Log.shared.info(
            "sink",
            SinkConfiguration.defaultPin.isEmpty
                ? "Cleared the stored certificate pin — the server now presents a publicly trusted certificate"
                : "Updated stored certificate pin after server certificate rotation"
        )
    }

    /// Metrics worth a deduplicated daily rollup. Deliberately a short list: the
    /// unit must be known ahead of the query, and these are the numbers most
    /// likely to drive a workflow.
    private static let statisticsMetrics = [
        "StepCount", "DistanceWalkingRunning", "DistanceCycling", "ActiveEnergyBurned",
        "BasalEnergyBurned", "FlightsClimbed", "AppleExerciseTime", "AppleStandTime",
        "RestingHeartRate", "HeartRateVariabilitySDNN", "BodyMass", "OxygenSaturation",
        "RespiratoryRate", "VO2Max", "DietaryEnergyConsumed", "DietaryWater"
    ]

    // MARK: - Entry points

    /// Full pass over every enabled type. Safe to call repeatedly; overlapping
    /// invocations are collapsed.
    func syncAll(reason: String) async {
        guard !isSyncing else {
            rerunRequested = true
            Log.shared.debug("sync", "Sync in progress; queued follow-up for \(reason)")
            return
        }
        guard authorization.isAvailable else {
            phase = .failed("HealthKit unavailable")
            return
        }
        guard UIApplication.shared.isProtectedDataAvailable else {
            // HealthKit is encrypted while locked. Not an error — just not now.
            phase = .waitingForUnlock
            Log.shared.info("sync", "Deferred \(reason): device locked, HealthKit unreadable")
            return
        }

        isSyncing = true
        rerunRequested = false

        let types = Array(authorization.enabledSampleTypes).sorted { $0.identifier < $1.identifier }
        guard !types.isEmpty else {
            phase = .failed("No metric groups enabled")
            isSyncing = false
            return
        }

        Log.shared.info("sync", "Starting sync (\(reason)) over \(types.count) types")
        await reconcileWithServer(types: types)
        let started = Date()
        var totalEmitted = 0
        var failures = 0

        for (index, type) in types.enumerated() {
            report(.syncing(metric: type.identifier.healthKitSlug,
                            progress: index + 1,
                            total: types.count))
            do {
                totalEmitted += try await drain(type: type)
            } catch let error as HealthReader.ReadError {
                if case .protectedDataUnavailable = error {
                    phase = .waitingForUnlock
                    Log.shared.warn("sync", "Device locked mid-sync; stopping cleanly")
                    break
                }
                failures += 1
                AnchorStore.shared.recordError(error.localizedDescription, for: type.identifier)
                Log.shared.error("sync", "\(type.identifier): \(error.localizedDescription)")
            } catch {
                failures += 1
                AnchorStore.shared.recordError(error.localizedDescription, for: type.identifier)
            }
        }

        totalEmitted += await syncStatistics()
        totalEmitted += await emitCharacteristicsIfNeeded()

        await deliverPending()

        settings.lastFullSyncAt = Date()
        let elapsed = Int(Date().timeIntervalSince(started))
        lastSummary = "\(totalEmitted) records in \(elapsed)s" + (failures > 0 ? ", \(failures) failed" : "")
        refreshCounts()
        // Preserve both terminal states rather than flattening to idle. The
        // read half of a run can finish perfectly while delivery is dead — an
        // expired token stops the upload circuit breaker, and overwriting that
        // with "idle" shows a green checkmark over a queue that is going
        // nowhere, which is worse than not detecting it at all. The next run
        // sets .syncing on entry, so neither state can linger once work
        // resumes.
        switch phase {
        case .waitingForUnlock, .failed: break
        default: phase = .idle
        }
        Log.shared.info("sync", "Finished: \(lastSummary ?? "")")
        // Housekeeping, so nothing waits on it. The archive has been measured
        // at 640MB after a first sync, and enumerating and deleting that on the
        // main actor is a stall for work no one is looking at.
        Task.detached(priority: .background) { await Outbox.shared.pruneArchiveOffMain() }

        isSyncing = false
        if rerunRequested {
            rerunRequested = false
            await syncDirtyTypes()
        }
    }

    /// Coalescing entry point for observer notifications.
    ///
    /// Never `await` a drain directly from an observer callback: 130 observers
    /// firing at registration would mean 130 concurrent drains. This collapses a
    /// burst into a single pass a few seconds later.
    func requestDirtyDrain() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.syncDirtyTypes()
        }
    }

    /// Only the types an observer flagged. Used on background wake so a nudge
    /// about step count doesn't walk all 130 types.
    func syncDirtyTypes() async {
        guard !isSyncing else {
            rerunRequested = true
            return
        }
        let dirty = AnchorStore.shared.dirtyTypes
        guard !dirty.isEmpty else { return }
        let types = authorization.enabledSampleTypes.filter { dirty.contains($0.identifier) }
        guard !types.isEmpty else { return }

        guard UIApplication.shared.isProtectedDataAvailable else {
            Log.shared.info("sync", "Dirty-type sync deferred: device locked")
            return
        }

        isSyncing = true
        rerunRequested = false

        Log.shared.info("sync", "Draining \(types.count) flagged type(s)")
        var emitted = 0
        for type in types {
            do { emitted += try await drain(type: type) } catch {
                AnchorStore.shared.recordError(error.localizedDescription, for: type.identifier)
            }
        }
        await deliverPending()
        refreshCounts()
        Log.shared.info("sync", "Flagged drain emitted \(emitted) records")

        isSyncing = false
    }

    // MARK: - Per-type drain

    /// Pages through everything new for one type. Returns records emitted.
    private func drain(type: HKSampleType) async throws -> Int {
        let identifier = type.identifier
        var anchor = AnchorStore.shared.anchor(for: identifier)
        var emitted = 0
        var pages = 0
        let cutoff = settings.backfillStartDate

        while true {
            // Reading, filtering and normalising all happen on HealthKit's own
            // queue now; what comes back is plain values. Nothing per-sample
            // touches the main actor in this loop.
            let page = try await reader.anchoredPage(type: type,
                                                     anchor: anchor,
                                                     limit: settings.pageSize,
                                                     cutoff: cutoff)

            if !page.records.isEmpty {
                // Encode and write happen off the main actor too; the await is
                // what keeps the ordering below honest.
                await Outbox.shared.write(page.records)
                emitted += page.records.count
            }

            // Anchor advances only now that the page is durably on disk. Doing
            // this earlier turns any failure into silent, undetectable data loss.
            await AnchorStore.shared.setAnchor(page.newAnchor,
                                               for: identifier,
                                               lastSampleEnd: page.newestEnd,
                                               added: page.records.count)
            anchor = page.newAnchor
            pages += 1

            guard page.likelyHasMore else { break }
            guard pages < 500 else {
                Log.shared.warn("sync", "\(identifier): stopped after \(pages) pages; will resume next run")
                break
            }
            // Yield so a long backfill doesn't starve the main actor.
            await Task.yield()
        }

        if pages > 1 {
            Log.shared.info("sync", "\(identifier.healthKitSlug): \(emitted) records over \(pages) pages")
        }
        return emitted
    }

    // MARK: - Statistics

    private func syncStatistics() async -> Int {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day,
                                          value: -settings.statisticsLookbackDays,
                                          to: end) ?? end
        var emitted: [HealthRecord] = []

        for name in SyncEngine.statisticsMetrics {
            guard let type = HKObjectType.quantityType(
                forIdentifier: MetricCatalog.quantityIdentifier(name)
            ) else { continue }
            guard let unit = UnitResolver.shared.staticUnit(for: type) else { continue }

            do {
                let stats = try await reader.dailyStatistics(type: type, from: start, to: end)
                for stat in stats {
                    if let record = Normalizer.statisticRecord(stat, unit: unit) {
                        emitted.append(record)
                    }
                }
            } catch {
                Log.shared.debug("stats", "\(name): \(error.localizedDescription)")
            }
        }

        guard !emitted.isEmpty else { return 0 }
        await Outbox.shared.write(emitted, windowFrom: start, windowTo: end)
        Log.shared.info("stats", "Emitted \(emitted.count) daily rollups")
        return emitted.count
    }

    // MARK: - Characteristics

    /// Wrapped in a struct rather than stored as a bare `Date?`: a top-level
    /// optional round-trips through JSON awkwardly.
    private struct CharacteristicsState: Codable {
        var lastEmittedAt: Date?
    }

    private let characteristicsStore = StateStore<CharacteristicsState>(
        filename: "characteristics.json",
        fallback: CharacteristicsState()
    )

    /// Static profile data — re-emitted monthly rather than every sync, since it
    /// changes approximately never.
    private func emitCharacteristicsIfNeeded() async -> Int {
        let last = characteristicsStore.value.lastEmittedAt ?? .distantPast
        guard Date().timeIntervalSince(last) > 30 * 86_400 else { return 0 }
        let records = reader.characteristics()
        guard !records.isEmpty else { return 0 }
        await Outbox.shared.write(records)
        characteristicsStore.mutate { $0.lastEmittedAt = Date() }
        return records.count
    }

    // MARK: - Reconciliation

    /// How far the server may lag the local anchors before it counts as a gap.
    ///
    /// Not zero, and not tight. `lastSampleEnd` is the end of the newest sample
    /// this device *read*, while coverage reports the newest the server has
    /// *stored*, behind a short cache — so a small lag is ordinary. A day is
    /// comfortably wider than that skew and far narrower than the kind of loss
    /// worth re-reading two years of history to repair.
    private static let coverageTolerance: TimeInterval = 24 * 3600

    /// Rewinds anchors for types the server turns out not to have, before the
    /// drain runs so the repair happens in this same pass.
    ///
    /// Anchors are otherwise the only record of what was delivered, and they
    /// only ever move forward. If the server loses data — restored from an older
    /// backup, a batch dropped, a table truncated — nothing on the phone
    /// notices: the anchor has already advanced past the gap, so those samples
    /// are never read again and the hole is permanent and silent. This is what
    /// closes that loop.
    ///
    /// Compares dates only, never counts. The server's per-metric count mixes
    /// raw samples with `stat:` rollups while `totalRecords` counts only what
    /// this device delivered, so the two are not comparable — a count check
    /// would rewind constantly.
    func reconcileWithServer(types: [HKSampleType]) async {
        guard settings.sink.enabled, settings.sink.isUsable, isSignedIn else { return }

        // Spooled-but-undelivered data makes the server legitimately behind.
        // Reconciling then would rewind an anchor, re-read history that is
        // already queued, spool more of it, and keep the outbox non-empty —
        // a loop that never settles.
        let queued = await Outbox.shared.pendingCountOffMain()
        guard queued == 0 else {
            Log.shared.debug("reconcile", "Skipped: \(queued) batch(es) still queued")
            return
        }

        let sink = HTTPSink(configuration: settings.sink)
        guard case .success(let coverage) = await sink.fetchCoverage() else {
            // A precondition for repair, not for syncing. If the server cannot
            // answer, this run just proceeds on local anchors as it always did.
            Log.shared.debug("reconcile", "Coverage unavailable; syncing on local anchors")
            return
        }

        var rewound = 0
        for type in types {
            let identifier = type.identifier
            guard let local = AnchorStore.shared.state(for: identifier),
                  local.totalRecords > 0,
                  let localEnd = local.lastSampleEnd else { continue }

            // The slug these records were *uploaded* under, which is not always
            // the one derived from the identifier.
            let slug = Normalizer.uploadSlug(for: type)
            let remote = coverage.metrics[slug]
            let cause: String?

            if remote == nil || remote?.count == 0 {
                cause = "server holds nothing for it, local delivered \(local.totalRecords)"
            } else if let remoteEnd = remote?.latestSampleEndDate,
                      localEnd.timeIntervalSince(remoteEnd) > SyncEngine.coverageTolerance {
                // Both sides are now describing the same instant. Comparing this
                // end against the server's newest *start* — which is what the
                // only available field used to mean — put a metric whose samples
                // span a week permanently a week behind itself, and rewound its
                // entire history on every launch.
                cause = "server's newest ends \(Timestamps.iso8601(remoteEnd)), "
                    + "local reached \(Timestamps.iso8601(localEnd))"
            } else {
                // A server too old to report the end date gets no date check at
                // all. The count check above still catches real loss, and a
                // wrong comparison is worse than a missing one: it re-reads
                // years of history to fix data that was never missing.
                cause = nil
            }

            guard let cause else { continue }
            AnchorStore.shared.clearAnchor(for: identifier)
            rewound += 1
            // Loud on purpose: re-reading a type's whole history is expensive
            // and user-visible, and must never happen without a trace.
            Log.shared.warn("reconcile", "Rewound \(slug) — \(cause)")
        }

        if rewound > 0 {
            Log.shared.warn("reconcile",
                "\(rewound) type(s) rewound; this run re-reads their history")
        }
    }

    // MARK: - Delivery

    /// Hands pending batches to the configured sink with bounded retries.
    func deliverPending() async {
        let sink: ExportSink = settings.sink.isUsable
            ? HTTPSink(configuration: settings.sink)
            : FileSink()

        // A directory listing plus a stat() per file. Cheap with ten batches
        // queued and not obviously cheap with several hundred, which is what a
        // stalled upload leaves behind.
        let pending = await Outbox.shared.pendingBatchesOffMain()
        guard !pending.isEmpty else { return }

        // FileSink is a no-op: the files stay put for the share sheet, which is
        // exactly the v1 behaviour. Nothing to deliver, nothing to archive.
        guard !(sink is FileSink) else {
            publishPendingBatches(pending.count)
            return
        }

        // A revoked or expired token fails every batch identically. Without a
        // circuit breaker, a backlog of thousands of batches becomes thousands
        // of pointless 401s — minutes of radio, and the real problem buried at
        // the bottom of the log.
        var consecutiveAuthFailures = 0
        let authFailureLimit = 3

        for (index, batch) in pending.enumerated() {
            report(.delivering(remaining: pending.count - index))
            var attempt = 0
            var delay: UInt64 = 2_000_000_000 // 2s

            while attempt < 4 {
                attempt += 1
                switch await sink.deliver(batch) {
                case .success:
                    Outbox.shared.archive(batch)
                    Log.shared.info("deliver", "\(batch.displayName) accepted")
                    consecutiveAuthFailures = 0
                    attempt = .max
                case .failure(let error):
                    let sinkError = error as? SinkError
                    if case .unauthorized = sinkError {
                        consecutiveAuthFailures += 1
                    } else if sinkError?.isRetryable != true {
                        consecutiveAuthFailures = 0
                    }
                    if sinkError?.isRetryable == true, attempt < 4 {
                        // Exponential backoff with jitter, capped.
                        let jitter = UInt64.random(in: 0...500_000_000)
                        try? await Task.sleep(nanoseconds: min(delay + jitter, 60_000_000_000))
                        delay *= 2
                    } else {
                        // Permanent failure: park it. Looping forever on a 400
                        // just burns battery and hides the problem.
                        Log.shared.error("deliver",
                            "\(batch.displayName) parked: \(error.localizedDescription)")
                        attempt = .max
                    }
                }
            }

            if consecutiveAuthFailures >= authFailureLimit {
                // Stop and say so plainly. The batches stay in the outbox, so
                // nothing is lost — this only avoids burning the backlog
                // against a credential that is not going to start working.
                phase = .failed("Server rejected the token — sign in again")
                Log.shared.error("deliver",
                    "Stopped after \(consecutiveAuthFailures) authentication failures; "
                    + "\(pending.count - index - 1) batch(es) left queued. Sign in again in Settings.")
                refreshCounts()
                return
            }
        }
        refreshCounts()
    }

    /// True once a token is held, whether it was pasted in or obtained by
    /// signing in.
    var isSignedIn: Bool { !bearerToken.isEmpty }

    /// Trades a username and password for a token. The password is used for the
    /// single request and never stored.
    func signIn(username: String, password: String) async {
        connectionTest = .running
        // No `await`: this method is already on the main actor, which is where
        // `UIDevice.current` lives, so the hop the compiler would have inserted
        // is to the actor it is standing on.
        let label = UIDevice.current.name
        let sink = HTTPSink(configuration: settings.sink)
        switch await sink.signIn(username: username, password: password, deviceLabel: label) {
        case .success(let message):
            objectWillChange.send()
            connectionTest = .succeeded(message)
            Log.shared.info("sink", "Signed in: \(message)")
        case .failure(let error):
            connectionTest = .failed(error.localizedDescription)
            Log.shared.error("sink", "Sign-in failed: \(error.localizedDescription)")
        }
    }

    /// Revokes the token server-side, then clears it locally.
    func signOut() async {
        let sink = HTTPSink(configuration: settings.sink)
        let result = await sink.signOut()
        objectWillChange.send()
        connectionTest = .untested
        // Uploading with no credential would just park every batch on a 401.
        settings.sink.enabled = false
        if case .failure(let error) = result {
            Log.shared.warn("sink", "Signed out locally, but the server was not reachable to revoke the token: \(error.localizedDescription)")
        } else {
            Log.shared.info("sink", "Signed out and revoked the token")
        }
    }

    /// Last successful reading of what the server holds, for the Server tab.
    @Published private(set) var serverStatus: ServerStatus?
    @Published private(set) var serverStatusError: String?
    @Published private(set) var isLoadingServerStatus = false

    /// Daily series behind the Status tab's charts.
    @Published private(set) var trends: AnalyticsOverview?

    func refreshTrends() async {
        guard settings.sink.endpoint != nil, isSignedIn else { return }
        let sink = HTTPSink(configuration: settings.sink)
        if case .success(let overview) = await sink.fetchOverview() {
            trends = overview
            saveCachedViews()
        }
        // Deliberately silent on failure: the charts are a nicety, and the
        // Server tab already surfaces connection problems properly. Throwing an
        // error banner onto the main screen for a decorative fetch would train
        // people to ignore the banner that matters.
    }

    // MARK: - Insights

    /// The deterministic analysis, and the last generated explanation of it.
    ///
    /// Kept apart deliberately. The snapshot is what was measured and loads in
    /// well under a second; an insight is an explanation that takes a local
    /// model tens of seconds and may not arrive at all. Storing them in one
    /// property would mean a failed generation blanking numbers that were never
    /// in doubt.
    @Published private(set) var snapshot: HealthSnapshot?
    @Published private(set) var snapshotError: String?
    @Published private(set) var insightError: String?
    @Published private(set) var insightStatus: InsightStatus?
    @Published private(set) var isAsking = false

    // MARK: - Conversations

    /// The conversation on screen, oldest turn first.
    ///
    /// This replaced a single `insight` and `lastQuestion`. The screen has
    /// always *looked* like a chat; holding one question and one answer meant
    /// asking a second thing silently erased the first, and a follow-up reached
    /// the model with no idea what came before.
    @Published private(set) var transcript: [ChatTurn] = []
    /// What the server is doing right now, while a question is in flight. Empty
    /// between questions and whenever the poll has nothing to report yet.
    @Published private(set) var askingLabel: String = ""
    /// Which conversation the next question joins. Nil means the next question
    /// opens one — the session is created by the ask itself, so a question that
    /// never lands cannot strand an empty chat in the history.
    @Published private(set) var activeSessionId: String?
    @Published private(set) var activeTitle: String?
    @Published private(set) var activeSummary: String?
    @Published private(set) var activeSummaryTurns = 0
    @Published private(set) var contextUsed: Double?
    @Published private(set) var pendingTurns = 0

    @Published private(set) var chats: [ChatSession] = []
    @Published private(set) var chatProjects: [ChatProject] = []
    @Published private(set) var totalChats = 0
    @Published private(set) var isLoadingChats = false
    /// Why the history list is empty, when the reason is not "there are none".
    ///
    /// Worth its own field: a failed request and an empty history look
    /// identical on screen otherwise, and "No chats yet" is a confident,
    /// wrong answer to give somebody whose token has just expired.
    @Published private(set) var chatsError: String?
    @Published private(set) var isLoadingTranscript = false
    @Published private(set) var isCompacting = false
    /// Said out loud rather than left to be noticed — a conversation that
    /// quietly forgets its opening is the failure this replaces.
    @Published var chatNotice: String?

    /// Which chat was open when the app was last closed.
    ///
    // MARK: - Cached views

    /// The last figures the server gave us, kept on disk.
    ///
    /// Everything on the first screen used to come from a network round trip, so
    /// every launch showed placeholder text until it landed — on a slow
    /// connection, or none, that was the whole experience of opening the app.
    /// None of it is secret from the person holding the phone and none of it
    /// changes minute to minute, so the honest default is to show what was true
    /// last time immediately, and correct it when the network answers.
    struct CachedViews: Codable {
        var snapshot: HealthSnapshot?
        var trends: AnalyticsOverview?
        var insightStatus: InsightStatus?
        var savedAt: Date?
    }

    private let viewCache = StateStore<CachedViews>(
        filename: "view-cache.json", fallback: CachedViews()
    )

    /// When the cached figures were written, so the UI can say how old they are
    /// rather than presenting them as current.
    @Published private(set) var cachedAt: Date?

    /// Publishes the cached figures. Anything already fetched this session wins.
    func restoreCachedViews() async {
        let store = viewCache
        let cached = await Task.detached(priority: .userInitiated) { store.value }.value
        if snapshot == nil { snapshot = cached.snapshot }
        if trends == nil { trends = cached.trends }
        if insightStatus == nil { insightStatus = cached.insightStatus }
        cachedAt = cached.savedAt

        // The conversation that was on screen last time is deliberately *not*
        // reopened. Arriving at the tab is arriving at a new question, and a
        // chat from days ago presented as though it were still going invites
        // asking a follow-up to something already answered. The old chat is one
        // tap away in the history drawer, which is where a finished conversation
        // belongs.
    }

    private func saveCachedViews() {
        let payload = CachedViews(
            snapshot: snapshot, trends: trends, insightStatus: insightStatus, savedAt: Date()
        )
        cachedAt = payload.savedAt
        let store = viewCache
        Task { await store.mutateOffMain { $0 = payload } }
    }

    func refreshSnapshot() async {
        guard settings.sink.endpoint != nil, isSignedIn else {
            snapshotError = "Sign in on the Settings tab to see your summary."
            return
        }
        let sink = HTTPSink(configuration: settings.sink)
        switch await sink.fetchSnapshot() {
        case .success(let value):
            snapshot = value
            snapshotError = nil
        case .failure(let error):
            // The previous reading is kept: stale numbers still say more than a
            // blank screen, and the error line says they are stale.
            snapshotError = error.localizedDescription
        }
        if case .success(let status) = await sink.fetchInsightStatus() {
            insightStatus = status
        }
        saveCachedViews()
    }

    func ask(_ question: String, context: String = "", remember: Bool = true) async {
        await run(question) { sink, sessionId, progressKey in
            await sink.ask(
                question: question, context: context, remember: remember,
                sessionId: sessionId, progressKey: progressKey
            )
        }
    }

    func requestWeeklyReview() async {
        await run("Weekly review") { sink, sessionId, _ in
            await sink.weeklyReview(sessionId: sessionId)
        }
    }

    /// Ask something, and put the answer where it belongs.
    ///
    /// The turn is appended before the request so the question appears the
    /// instant it is sent rather than half a minute later with the reply. It is
    /// completed in place afterwards, which is why `ChatTurn` carries a stable
    /// id: SwiftUI animates the bubble filling in instead of swapping one row
    /// for another.
    private func run(
        _ question: String,
        _ call: @escaping (HTTPSink, String?, String) async -> Result<InsightResult, Error>
    ) async {
        guard !isAsking, settings.sink.endpoint != nil, isSignedIn else { return }
        isAsking = true
        insightError = nil
        chatNotice = nil

        let pending = ChatTurn(question: question, isPending: true)
        transcript.append(pending)

        // The key is minted here, before the request, so the poll can start
        // while the answer is still being written — which is the whole point,
        // since the request is what takes fifteen to ninety seconds.
        let progressKey = UUID().uuidString
        let watcher = watchProgress(key: progressKey)
        defer {
            watcher.cancel()
            askingLabel = ""
            isAsking = false
        }

        let sink = HTTPSink(configuration: settings.sink)
        switch await call(sink, activeSessionId, progressKey) {
        case .success(let result):
            if let index = transcript.firstIndex(where: { $0.id == pending.id }) {
                transcript[index].complete(with: result)
            }
            // The server says which conversation the turn landed in, including
            // when it just opened one.
            if let sessionId = result.sessionId {
                adopt(sessionId)
            }
            if let folded = result.compacted, folded > 0 {
                chatNotice = "Compacted \(folded) earlier messages to fit the model\u{2019}s context. Nothing was deleted."
                await refreshActiveTranscript()
            }
            await loadChats()
        case .failure(let error):
            transcript.removeAll { $0.id == pending.id }
            insightError = error.localizedDescription
            Log.shared.error("insight", "Question failed: \(error.localizedDescription)")
        }
    }

    /// Polls what the server is doing, for as long as the answer takes.
    ///
    /// Every failure is silent and terminal: this is decoration over a request
    /// that is working perfectly well without it, so a poll that throttles,
    /// 404s or times out simply stops and leaves the last label on screen. It
    /// must never be able to surface an error beside an answer that is about to
    /// arrive.
    private func watchProgress(key: String) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                let sink = HTTPSink(configuration: self.settings.sink)
                switch await sink.insightProgress(key: key) {
                case .success(let note):
                    if note.done { return }
                    if !note.label.isEmpty { self.askingLabel = note.label }
                case .failure:
                    return
                }
            }
        }
    }

    private func adopt(_ sessionId: String) {
        guard activeSessionId != sessionId else { return }
        activeSessionId = sessionId
    }

    /// Start a new conversation. Nothing is created server-side until the first
    /// question — an empty chat in the history is a piece of litter nobody can
    /// tell apart from a real one.
    func newChat() {
        transcript = []
        activeSessionId = nil
        activeTitle = nil
        activeSummary = nil
        activeSummaryTurns = 0
        contextUsed = nil
        pendingTurns = 0
        insightError = nil
        chatNotice = nil
    }

    func openChat(_ sessionId: String) async {
        guard settings.sink.endpoint != nil, isSignedIn, !isAsking else { return }
        isLoadingTranscript = true
        insightError = nil
        chatNotice = nil
        defer { isLoadingTranscript = false }

        let sink = HTTPSink(configuration: settings.sink)
        switch await sink.chatTranscript(sessionId) {
        case .success(let body):
            apply(body)
            adopt(body.id)
        case .failure(let error):
            insightError = error.localizedDescription
        }
    }

    private func apply(_ body: ChatTranscript) {
        // A turn already on screen keeps the identity SwiftUI knows it by. This
        // runs on every reload, including the one that follows a compaction
        // *during* a conversation — without it, the answer that had just landed
        // is a different row to SwiftUI than the one it replaces, so the bubble
        // the reader is looking at is torn down and rebuilt underneath them.
        let known = Dictionary(
            transcript.compactMap { turn in turn.storedId.map { ($0, turn.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        transcript = body.messages.map { message in
            var turn = ChatTurn(stored: message)
            if let existing = known[message.id] { turn.id = existing }
            return turn
        }
        activeTitle = body.title
        activeSummary = body.summary
        activeSummaryTurns = body.summaryTurns
        contextUsed = body.context?.used
        pendingTurns = body.context?.pendingTurns ?? 0
    }

    private func refreshActiveTranscript() async {
        guard let sessionId = activeSessionId else { return }
        let sink = HTTPSink(configuration: settings.sink)
        if case .success(let body) = await sink.chatTranscript(sessionId) {
            apply(body)
        }
    }

    /// The history list. Titles only — the transcript is fetched when a chat is
    /// opened, and only then.
    func loadChats(search: String = "", more: Bool = false) async {
        guard settings.sink.endpoint != nil, isSignedIn else { return }
        isLoadingChats = true
        defer { isLoadingChats = false }

        let sink = HTTPSink(configuration: settings.sink)
        let offset = more ? chats.count : 0
        switch await sink.chatSessions(offset: offset, search: search) {
        case .success(let page):
            chats = more ? chats + page.sessions : page.sessions
            totalChats = page.total
            chatsError = nil
        case .failure(let error):
            chatsError = error.localizedDescription
            Log.shared.error("insight", "Could not list chats: \(error.localizedDescription)")
        }
        if case .success(let list) = await sink.chatProjects() {
            chatProjects = list.projects
        }
    }

    var hasMoreChats: Bool { chats.count < totalChats }

    func renameChat(_ sessionId: String, to title: String) async {
        let sink = HTTPSink(configuration: settings.sink)
        if case .success = await sink.renameChat(sessionId, title: title) {
            if sessionId == activeSessionId { activeTitle = title }
            await loadChats()
        }
    }

    func archiveChat(_ sessionId: String) async {
        let sink = HTTPSink(configuration: settings.sink)
        if case .success = await sink.archiveChat(sessionId, archived: true) {
            if sessionId == activeSessionId { newChat() }
            await loadChats()
        }
    }

    func deleteChat(_ sessionId: String) async {
        let sink = HTTPSink(configuration: settings.sink)
        switch await sink.deleteChat(sessionId) {
        case .success:
            if sessionId == activeSessionId { newChat() }
            await loadChats()
        case .failure(let error):
            insightError = error.localizedDescription
        }
    }

    /// Fold the older half of this conversation into a written summary.
    ///
    /// Affects what the model is sent, never the transcript: destroying what was
    /// actually said to save room would be a strange trade in a system built
    /// around answers you can go back and check.
    func compactActiveChat() async {
        guard let sessionId = activeSessionId, !isCompacting, !isAsking else { return }
        isCompacting = true
        chatNotice = nil
        defer { isCompacting = false }

        let sink = HTTPSink(configuration: settings.sink)
        switch await sink.compactChat(sessionId) {
        case .success(let result):
            chatNotice = result.compacted
                ? "Compacted \(result.turns) earlier messages. The transcript is unchanged."
                : "Nothing compacted: \(result.reason ?? "not enough conversation yet")."
            await refreshActiveTranscript()
        case .failure(let error):
            insightError = error.localizedDescription
        }
    }

    /// Record what you made of one answer.
    ///
    /// Updated from the server's reply rather than optimistically: this is the
    /// data a feedback loop is built on, and a thumb that looks saved but is not
    /// would poison it quietly.
    func rate(turnId: Int, rating: Int?, note: String? = nil) async {
        let sink = HTTPSink(configuration: settings.sink)
        switch await sink.rateAnswer(turnId, rating: rating, note: note) {
        case .success(let updated):
            if let index = transcript.firstIndex(where: { $0.storedId == turnId }) {
                transcript[index].rating = updated.rating
                transcript[index].note = updated.note
            }
        case .failure(let error):
            insightError = error.localizedDescription
        }
    }

    func refreshServerStatus(fresh: Bool = false) async {
        guard settings.sink.endpoint != nil, isSignedIn else {
            serverStatusError = "Sign in first."
            return
        }
        isLoadingServerStatus = true
        defer { isLoadingServerStatus = false }

        let sink = HTTPSink(configuration: settings.sink)
        switch await sink.fetchStatus(fresh: fresh) {
        case .success(let status):
            serverStatus = status
            serverStatusError = nil
        case .failure(let error):
            // The previous reading is deliberately kept: a failed refresh
            // should not blank the screen, since stale numbers still say more
            // than nothing at all.
            serverStatusError = error.localizedDescription
        }
    }

    /// One round trip to the destination's ping endpoint, carrying no health
    /// data. Background sync fails quietly — a stale token, a mistyped URL, or
    /// a certificate that no longer matches the pin all look identical to
    /// "nothing has happened yet" until someone checks.
    func testConnection() async {
        connectionTest = .running
        let sink = HTTPSink(configuration: settings.sink)
        switch await sink.probe() {
        case .success(let message):
            connectionTest = .succeeded(message)
            Log.shared.info("sink", "Connection test succeeded: \(message)")
        case .failure(let error):
            let detail = error.localizedDescription
            connectionTest = .failed(detail)
            Log.shared.error("sink", "Connection test failed: \(detail)")
        }
    }

    // MARK: - Maintenance

    func resetSyncState() {
        AnchorStore.shared.resetAll()
        lastSummary = "Anchors cleared"
    }

    /// Fire-and-forget: callers are views appearing, and none of them should
    /// wait on a directory listing to draw.
    ///
    /// The request token is what makes that safe. Counting the queue moved off
    /// the main thread, which means a read can still be in flight when delivery
    /// finishes and publishes zero — and the older read then lands last and puts
    /// the number back up. That is a queue reported as stuck with an empty
    /// outbox behind it: uploads working perfectly, and a UI saying otherwise.
    func refreshCounts() {
        pendingCountRequest += 1
        let request = pendingCountRequest
        Task {
            let count = await Outbox.shared.pendingCountOffMain()
            // Somebody published a newer figure while this was reading. They
            // know something this read does not.
            guard request == pendingCountRequest else { return }
            pendingBatches = count
        }
    }

    /// Publishes a count directly, invalidating any read still in flight.
    private func publishPendingBatches(_ value: Int) {
        pendingCountRequest += 1
        pendingBatches = value
    }

    private var pendingCountRequest = 0
}
