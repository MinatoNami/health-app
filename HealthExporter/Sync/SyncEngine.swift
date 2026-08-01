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

    init(authorization: HealthAuthorization) {
        self.authorization = authorization
        self.reader = HealthReader(healthStore: authorization.healthStore)
        self.settings = settingsStore.value
        self.pendingBatches = Outbox.shared.pendingCount
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

    /// Moves a stored pin forward when the server certificate has been rotated.
    ///
    /// The persisted value wins over `defaultPin`, so without this a rotation
    /// would strand every existing install on a pin that no longer matches —
    /// visible only as uploads that silently stop.
    private func migrateSupersededPin() {
        let stored = CertificatePinner.normalize(settings.sink.pinnedCertificateSHA256)
        guard SinkConfiguration.supersededPins.contains(stored) else { return }
        settings.sink.pinnedCertificateSHA256 = SinkConfiguration.defaultPin
        Log.shared.info("sink", "Updated stored certificate pin after server certificate rotation")
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
        let started = Date()
        var totalEmitted = 0
        var failures = 0

        for (index, type) in types.enumerated() {
            phase = .syncing(metric: type.identifier.healthKitSlug,
                             progress: index + 1,
                             total: types.count)
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
        totalEmitted += emitCharacteristicsIfNeeded()

        await deliverPending()

        settings.lastFullSyncAt = Date()
        let elapsed = Int(Date().timeIntervalSince(started))
        lastSummary = "\(totalEmitted) records in \(elapsed)s" + (failures > 0 ? ", \(failures) failed" : "")
        pendingBatches = Outbox.shared.pendingCount
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
        Outbox.shared.pruneArchive()

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
        pendingBatches = Outbox.shared.pendingCount
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
            let page = try await reader.anchoredPage(type: type,
                                                     anchor: anchor,
                                                     limit: settings.pageSize)
            var records: [HealthRecord] = []
            records.reserveCapacity(page.added.count)
            var newestEnd: Date?

            for (offset, sample) in page.added.enumerated() {
                // HealthKit samples are Objective-C objects that pile up in the
                // autorelease pool. Without draining it per sample, a page of
                // 2,000 (times hundreds of pages) is a steady climb to a jetsam
                // kill rather than flat memory use.
                autoreleasepool {
                    // Read but don't emit pre-cutoff samples: the anchor still
                    // advances past them, so history is consumed without paying
                    // to normalize and ship data the user didn't ask for.
                    guard sample.endDate >= cutoff else { return }
                    if let record = Normalizer.record(from: sample) {
                        records.append(record)
                        if sample.endDate > (newestEnd ?? .distantPast) {
                            newestEnd = sample.endDate
                        }
                    }
                }
                // Normalization runs on the main actor, so yield periodically to
                // keep the UI responsive instead of hanging for seconds at a time.
                if offset % 200 == 199 { await Task.yield() }
            }
            // Tombstones carry no type or date, only a UUID. Emitting them is
            // what keeps the destination from diverging permanently.
            for deleted in page.deleted {
                records.append(HealthRecord.deletion(uuid: deleted.uuid))
            }

            if !records.isEmpty {
                Outbox.shared.write(records)
                emitted += records.count
            }

            // Anchor advances only now that the page is durably on disk. Doing
            // this earlier turns any failure into silent, undetectable data loss.
            AnchorStore.shared.setAnchor(page.newAnchor,
                                         for: identifier,
                                         lastSampleEnd: newestEnd,
                                         added: records.count)
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
        Outbox.shared.write(emitted, windowFrom: start, windowTo: end)
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
    private func emitCharacteristicsIfNeeded() -> Int {
        let last = characteristicsStore.value.lastEmittedAt ?? .distantPast
        guard Date().timeIntervalSince(last) > 30 * 86_400 else { return 0 }
        let records = reader.characteristics()
        guard !records.isEmpty else { return 0 }
        Outbox.shared.write(records)
        characteristicsStore.mutate { $0.lastEmittedAt = Date() }
        return records.count
    }

    // MARK: - Delivery

    /// Hands pending batches to the configured sink with bounded retries.
    func deliverPending() async {
        let sink: ExportSink = settings.sink.isUsable
            ? HTTPSink(configuration: settings.sink)
            : FileSink()

        let pending = Outbox.shared.pendingBatches()
        guard !pending.isEmpty else { return }

        // FileSink is a no-op: the files stay put for the share sheet, which is
        // exactly the v1 behaviour. Nothing to deliver, nothing to archive.
        guard !(sink is FileSink) else {
            pendingBatches = pending.count
            return
        }

        // A revoked or expired token fails every batch identically. Without a
        // circuit breaker, a backlog of thousands of batches becomes thousands
        // of pointless 401s — minutes of radio, and the real problem buried at
        // the bottom of the log.
        var consecutiveAuthFailures = 0
        let authFailureLimit = 3

        for (index, batch) in pending.enumerated() {
            phase = .delivering(remaining: pending.count - index)
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
                pendingBatches = Outbox.shared.pendingCount
                return
            }
        }
        pendingBatches = Outbox.shared.pendingCount
    }

    /// True once a token is held, whether it was pasted in or obtained by
    /// signing in.
    var isSignedIn: Bool { !bearerToken.isEmpty }

    /// Trades a username and password for a token. The password is used for the
    /// single request and never stored.
    func signIn(username: String, password: String) async {
        connectionTest = .running
        let label = await UIDevice.current.name
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
    @Published private(set) var insight: InsightResult?
    @Published private(set) var insightError: String?
    @Published private(set) var insightStatus: InsightStatus?
    @Published private(set) var isAsking = false

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
    }

    func ask(_ question: String, context: String = "", remember: Bool = true) async {
        guard !isAsking, settings.sink.endpoint != nil, isSignedIn else { return }
        isAsking = true
        insightError = nil
        defer { isAsking = false }

        let sink = HTTPSink(configuration: settings.sink)
        switch await sink.ask(question: question, context: context, remember: remember) {
        case .success(let result):
            insight = result
        case .failure(let error):
            insightError = error.localizedDescription
            Log.shared.error("insight", "Question failed: \(error.localizedDescription)")
        }
    }

    func requestWeeklyReview() async {
        guard !isAsking, settings.sink.endpoint != nil, isSignedIn else { return }
        isAsking = true
        insightError = nil
        defer { isAsking = false }

        let sink = HTTPSink(configuration: settings.sink)
        switch await sink.weeklyReview() {
        case .success(let result):
            insight = result
        case .failure(let error):
            insightError = error.localizedDescription
        }
    }

    func clearInsight() {
        insight = nil
        insightError = nil
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

    func refreshCounts() {
        pendingBatches = Outbox.shared.pendingCount
    }
}
