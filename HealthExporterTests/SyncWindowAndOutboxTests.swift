import XCTest
@testable import HealthExporter

/// Two ways the sync path used to lose data without saying so.
///
/// The rollup window started at "now minus N days", so its oldest day was read
/// from the current time of day onwards and that partial total replaced the
/// complete one on the server. And a batch that failed to reach disk returned an
/// empty list the caller ignored, so the sync anchor moved past it anyway.
final class SyncWindowAndOutboxTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - Statistics window

    func testWindowStartsAtLocalMidnight() {
        let now = date(2026, 10, 13, 14, 37)
        let window = SyncEngine.statisticsWindow(now: now, lookbackDays: 90, calendar: calendar)

        XCTAssertEqual(window.start, calendar.startOfDay(for: window.start),
                       "a start partway through a day makes the oldest rollup a partial day")
        XCTAssertEqual(window.start, date(2026, 7, 15))
        XCTAssertEqual(window.end, now)
    }

    func testWindowStartIsTheSameAllDay() {
        // Every run on a given day must agree on the oldest day it covers, or
        // the last run of the day decides how much of that day gets stored.
        let morning = SyncEngine.statisticsWindow(now: date(2026, 10, 13, 0, 5),
                                                  lookbackDays: 90, calendar: calendar)
        let night = SyncEngine.statisticsWindow(now: date(2026, 10, 13, 23, 55),
                                                lookbackDays: 90, calendar: calendar)
        XCTAssertEqual(morning.start, night.start)
    }

    // MARK: - Outbox write failures

    private let record = HealthRecord.deletion(uuid: UUID())

    func testWriteThrowsWhenTheFileCannotBeCreated() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-that-does-not-exist-\(UUID().uuidString)")
            .appendingPathComponent("nested")
        let outbox = Outbox(directory: missing)

        do {
            _ = try await outbox.write([record])
            XCTFail("a write that put nothing on disk must not look like success")
        } catch {
            guard case Outbox.WriteError.commitFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testWriteThrowsWithoutADirectory() async {
        do {
            _ = try await Outbox(directory: nil).write([record])
            XCTFail("expected noOutboxDirectory")
        } catch {
            guard case Outbox.WriteError.noOutboxDirectory = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testEmptyWriteIsNotAnError() async throws {
        // "Nothing to write" is the one empty result that is genuinely fine.
        let written = try await Outbox(directory: nil).write([])
        XCTAssertTrue(written.isEmpty)
    }

    func testWriteLandsOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let written = try await Outbox(directory: dir).write([record])

        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written[0].path))
        XCTAssertEqual(Outbox.Batch.recordCount(from: written[0]), 1)
    }
}

/// Days that aged out of the lookback before the window fix were stored as
/// partial days, and the rolling lookback never reaches them again — so the
/// one-off rebuild has to cover the whole backfill history.
final class RollupRebuildWindowTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testFullHistoryReachesTheBackfillDay() {
        let backfill = date(2024, 10, 13, 15)
        let now = date(2026, 10, 13, 9)
        let days = SyncEngine.fullHistoryDays(backfillStart: backfill, now: now, calendar: calendar)
        let window = SyncEngine.statisticsWindow(now: now, lookbackDays: days, calendar: calendar)

        XCTAssertEqual(window.start, calendar.startOfDay(for: backfill),
                       "the rebuild must start on the backfill day itself, from midnight")
    }

    func testABackfillDateInTheFutureIsNoWindowAtAll() {
        let days = SyncEngine.fullHistoryDays(backfillStart: date(2027, 1, 1),
                                              now: date(2026, 10, 13), calendar: calendar)
        XCTAssertEqual(days, 0)
    }
}

/// A batch the server refused used to stay in the queue forever: retried every
/// run, and keeping the queue from ever emptying, which is what reconciliation
/// waits for. It is set aside now, and has to be able to come back.
final class RejectedBatchTests: XCTestCase {

    func testARejectedBatchLeavesTheQueueAndCanReturn() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = Outbox(directory: dir)

        _ = try await outbox.write([HealthRecord.deletion(uuid: UUID())])
        let batch = try XCTUnwrap(outbox.pendingBatches().first)

        outbox.reject(batch)
        XCTAssertEqual(outbox.pendingCount, 0, "a rejected batch must stop blocking the queue")

        outbox.requeueRejected()
        XCTAssertEqual(outbox.pendingBatches().map(\.id), [batch.id])
    }
}

/// Batch files moved out of Documents, where file sharing put them in the
/// Files app. An install upgrading from that build has its queue there, and the
/// queue is the only copy of data whose anchors have already moved on.
final class BatchDirectoryMigrationTests: XCTestCase {

    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testQueuedBatchesMoveAndTheOldFolderGoes() throws {
        let legacy = try tempDir("Documents-Outbox")
        let dest = try tempDir("Support-Outbox")
        for name in ["batch-a-1.ndjson", "batch-b-2.ndjson"] {
            try Data("{}\n".utf8).write(to: legacy.appendingPathComponent(name))
        }

        XCTAssertEqual(Paths.moveContents(of: legacy, into: dest), 2)

        let landed = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        XCTAssertEqual(landed, ["batch-a-1.ndjson", "batch-b-2.ndjson"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "an emptied Documents folder would still show up in Files")
    }

    func testAHalfFinishedMoveIsCompletedNotDuplicated() throws {
        let legacy = try tempDir("Documents-Outbox")
        let dest = try tempDir("Support-Outbox")
        try Data("old\n".utf8).write(to: legacy.appendingPathComponent("batch-a-1.ndjson"))
        try Data("moved\n".utf8).write(to: dest.appendingPathComponent("batch-a-1.ndjson"))

        XCTAssertEqual(Paths.moveContents(of: legacy, into: dest), 0)

        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("batch-a-1.ndjson"), encoding: .utf8),
                       "moved\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testBatchDirectoriesAreNotInDocuments() throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory,
                                                                 in: .userDomainMask).first)
        for dir in [Paths.outboxDirectory, Paths.archiveDirectory, Paths.rejectedDirectory] {
            let path = try XCTUnwrap(dir).standardizedFileURL.path
            XCTAssertFalse(path.hasPrefix(documents.standardizedFileURL.path), path)
        }
    }
}

/// Against an unreachable server every batch used to get four attempts and up
/// to four 60-second timeouts — minutes per batch, for the whole queue.
final class UploadBreakerTests: XCTestCase {

    func testOneBadBatchIsNotAnOutage() {
        var breaker = UploadBreaker()
        XCTAssertFalse(breaker.recordExhausted())
        XCTAssertFalse(breaker.isOpen)
        XCTAssertEqual(breaker.attemptsForNextBatch, UploadBreaker.attemptsPerBatch)
    }

    func testTwoInARowStopTheRunAndTheNextRunProbesOnce() {
        var breaker = UploadBreaker()
        _ = breaker.recordExhausted()
        XCTAssertTrue(breaker.recordExhausted(), "the run should stop here")
        XCTAssertTrue(breaker.isOpen)
        XCTAssertEqual(breaker.attemptsForNextBatch, 1)

        // The probe fails too: stop after that one request.
        XCTAssertTrue(breaker.recordExhausted())
    }

    func testADeliveredProbeRestoresFullPatience() {
        var breaker = UploadBreaker()
        _ = breaker.recordExhausted()
        _ = breaker.recordExhausted()

        breaker.recordDelivered()

        XCTAssertFalse(breaker.isOpen)
        XCTAssertEqual(breaker.attemptsForNextBatch, UploadBreaker.attemptsPerBatch)
        XCTAssertFalse(breaker.recordExhausted(), "the count starts again from zero")
    }

    func testAnAnswerFromTheServerBreaksTheStreak() {
        // A rejected or parked batch means the server is there.
        var breaker = UploadBreaker()
        _ = breaker.recordExhausted()
        breaker.recordAnswered()
        XCTAssertFalse(breaker.recordExhausted())
    }

    func testBackoffHonoursRetryAfterWithinReason() {
        XCTAssertEqual(UploadBreaker.backoff(attempt: 1, retryAfter: "30"), 30)
        XCTAssertEqual(UploadBreaker.backoff(attempt: 1, retryAfter: "3600"), 60)
        XCTAssertEqual(UploadBreaker.backoff(attempt: 1, retryAfter: nil, jitter: 0), 2)
        XCTAssertEqual(UploadBreaker.backoff(attempt: 3, retryAfter: nil, jitter: 0), 8)
        // An HTTP-date Retry-After is not a number of seconds; fall back.
        XCTAssertEqual(UploadBreaker.backoff(attempt: 2, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT", jitter: 0), 4)
    }
}

/// The loop itself, against a sink that fails on cue. `Retry-After: 0` keeps
/// the backoff from sleeping, so this measures attempts rather than time.
@MainActor
final class DeliveryBreakerTests: XCTestCase {

    private final class FakeSink: ExportSink {
        let name = "fake"
        let isConfigured = true
        var reachable = false
        var calls = 0
        func deliver(_ batch: Outbox.Batch) async -> Result<Void, Error> {
            calls += 1
            return reachable
                ? .success(())
                : .failure(SinkError.retryable(status: 503, retryAfter: "0", underlying: nil))
        }
    }

    private func batches(_ count: Int) -> [Outbox.Batch] {
        (0..<count).map { i in
            Outbox.Batch(url: URL(fileURLWithPath: "/nonexistent/batch-\(i)-1.ndjson"),
                         createdAt: Date(), byteCount: 0, recordCount: 1)
        }
    }

    func testAnUnreachableServerCostsTwoBatchesThenOneRequestPerRun() async {
        let engine = SyncEngine(authorization: HealthAuthorization())
        let sink = FakeSink()

        await engine.deliver(batches(50), via: sink)
        XCTAssertEqual(sink.calls, 2 * UploadBreaker.attemptsPerBatch,
                       "two full batches of attempts, then stop — not 50 of them")
        XCTAssertEqual(engine.phase, .failed(SyncEngine.unreachableMessage))

        sink.calls = 0
        await engine.deliver(batches(50), via: sink)
        XCTAssertEqual(sink.calls, 1, "while open, a run is a single probe")

        sink.calls = 0
        sink.reachable = true
        await engine.deliver(batches(5), via: sink)
        XCTAssertEqual(sink.calls, 5, "a successful probe closes it and the run carries on")
        XCTAssertNotEqual(engine.phase, .failed(SyncEngine.unreachableMessage))
    }
}

/// Two delivery passes over the same queue upload every batch twice and race to
/// archive the same files. The locked-device path, the background refresh and
/// the retry button all reach delivery without going through `isSyncing`.
@MainActor
final class DeliveryOverlapTests: XCTestCase {

    private final class SlowSink: ExportSink {
        let name = "slow"
        let isConfigured = true
        var calls = 0
        func deliver(_ batch: Outbox.Batch) async -> Result<Void, Error> {
            calls += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
            return .success(())
        }
    }

    func testAnOverlappingPassDoesNotUploadTheQueueAgain() async {
        let engine = SyncEngine(authorization: HealthAuthorization())
        let sink = SlowSink()
        let queue = (0..<5).map { i in
            Outbox.Batch(url: URL(fileURLWithPath: "/nonexistent/overlap-\(i)-1.ndjson"),
                         createdAt: Date(), byteCount: 0, recordCount: 1)
        }

        async let first: Void = engine.deliver(queue, via: sink)
        async let second: Void = engine.deliver(queue, via: sink)
        _ = await (first, second)

        XCTAssertEqual(sink.calls, 5, "each batch once, not once per caller")
    }
}
