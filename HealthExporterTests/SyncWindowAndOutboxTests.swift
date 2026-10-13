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
