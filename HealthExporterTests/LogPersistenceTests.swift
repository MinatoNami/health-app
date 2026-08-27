import XCTest
@testable import HealthExporter

/// The debounce, which is the part of the log that has lied.
///
/// A leading-edge-only debounce drops whatever is logged in the two seconds
/// before the app goes quiet — and those are the lines that say how the session
/// ended. On a real phone it produced a sync with no "Finished" line and
/// deliveries that had all been accepted, which reads as a hang. These pin the
/// behaviour that stops it happening a fourth time.
final class LogPersistenceTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("sync.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Reads the file back, waiting only as long as it takes.
    private func persisted(within seconds: TimeInterval) -> [Log.Entry] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let data = try? Data(contentsOf: fileURL),
               let entries = try? JSONDecoder().decode([Log.Entry].self, from: data),
               !entries.isEmpty {
                return entries
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        return (try? JSONDecoder().decode([Log.Entry].self, from: data)) ?? []
    }

    private func waitFor(_ condition: () -> Bool, upTo seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testTheFirstEntryIsWrittenImmediately() {
        let log = Log(fileURL: fileURL)
        log.info("sync", "Starting sync")
        XCTAssertEqual(persisted(within: 2).map(\.message), ["Starting sync"])
    }

    func testTheTailIsWrittenAfterLoggingGoesQuiet() {
        // The regression. The second entry lands inside the debounce window, so
        // the leading edge skips it — and with no trailing write it was never
        // persisted at all.
        let log = Log(fileURL: fileURL)
        log.info("sync", "Starting sync")
        XCTAssertTrue(waitFor({ !self.persisted(within: 0).isEmpty }, upTo: 2))

        log.info("sync", "Finished: 954 records in 4s")
        XCTAssertFalse(
            persisted(within: 0).contains { $0.message.hasPrefix("Finished") },
            "the debounce should still be holding this one back"
        )

        let landed = waitFor(
            { self.persisted(within: 0).contains { $0.message.hasPrefix("Finished") } },
            upTo: 6
        )
        XCTAssertTrue(landed, "the trailing write never fired; the tail is lost again")
    }

    func testABurstCollapsesToOneTrailingWrite() {
        // The reason the debounce exists at all: a sync logs a line per batch,
        // and each one must not rewrite the file. All of them still have to be
        // on disk once it stops.
        let log = Log(fileURL: fileURL)
        for i in 0..<200 { log.info("deliver", "batch-\(i) accepted") }

        let all = waitFor(
            { self.persisted(within: 0).contains { $0.message == "batch-199 accepted" } },
            upTo: 6
        )
        XCTAssertTrue(all, "the last line of a burst is exactly what went missing before")
        XCTAssertEqual(persisted(within: 0).count, 200)
    }

    func testFlushDoesNotWaitForTheWindow() {
        // Backgrounding cannot wait: a suspended process does not run scheduled
        // work, so flush has to bypass the debounce rather than re-arm it.
        let log = Log(fileURL: fileURL)
        log.info("sync", "Starting sync")
        XCTAssertTrue(waitFor({ !self.persisted(within: 0).isEmpty }, upTo: 2))

        log.info("app", "Backgrounded")
        log.flush()

        let landed = waitFor(
            { self.persisted(within: 0).contains { $0.message == "Backgrounded" } },
            upTo: 1
        )
        XCTAssertTrue(landed, "flush should not have been subject to the debounce")
    }

    func testClearingEmptiesTheFileEvenInsideTheWindow() {
        // Went through the debounced path before, so a clear issued within two
        // seconds of a write never reached disk and the entries came back on
        // the next launch.
        let log = Log(fileURL: fileURL)
        log.info("sync", "Starting sync")
        XCTAssertTrue(waitFor({ !self.persisted(within: 0).isEmpty }, upTo: 2))

        log.clear()

        let emptied = waitFor({
            guard let data = try? Data(contentsOf: self.fileURL),
                  let entries = try? JSONDecoder().decode([Log.Entry].self, from: data)
            else { return false }
            return entries.isEmpty
        }, upTo: 2)
        XCTAssertTrue(emptied, "clear left the old entries on disk")
    }
}
