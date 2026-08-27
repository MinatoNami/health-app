import Foundation
import os

/// Timestamps for the launch path, because launch performance is the one thing
/// that cannot be judged from a simulator.
///
/// Everything here is fast on a Mac: the disk is an SSD pretending to be a
/// phone's, HealthKit is empty, and the XPC calls to `healthd` that dominate a
/// real first launch either return instantly or fail. The only way to know
/// where the seconds go is to measure on the device, so each stage logs its
/// offset from process start and the whole run prints one summary line.
///
/// Read it with the app attached, or afterwards:
///
///     log show --predicate 'subsystem == "com.lionelchong.HealthExporter"' --last 5m
enum LaunchTrace {
    private static let signposter = OSSignposter(
        subsystem: "com.lionelchong.HealthExporter", category: "launch"
    )
    private static let log = Logger(
        subsystem: "com.lionelchong.HealthExporter", category: "launch"
    )

    /// Process start, near enough. Set the first time anything touches this,
    /// which is `AppServices.init` — the earliest code this app owns.
    private static let started = ContinuousClock.now
    private static let lock = NSLock()
    nonisolated(unsafe) private static var marks: [(String, Duration)] = []

    /// Records a stage and how long after launch it happened.
    static func mark(_ stage: String) {
        let elapsed = ContinuousClock.now - started
        lock.lock()
        marks.append((stage, elapsed))
        lock.unlock()
        log.info("launch \(stage, privacy: .public) at +\(ms(elapsed), privacy: .public)ms")
    }

    /// Times one stage and marks its end. The interval also shows up in
    /// Instruments, where the gaps between stages are the interesting part.
    @discardableResult
    static func measure<T>(_ stage: String, _ work: () async -> T) async -> T {
        let state = signposter.beginInterval("launch", id: signposter.makeSignpostID())
        let begun = ContinuousClock.now
        let result = await work()
        let took = ContinuousClock.now - begun
        signposter.endInterval("launch", state)
        log.info("launch \(stage, privacy: .public) took \(ms(took), privacy: .public)ms")
        mark(stage)
        return result
    }

    /// One line with the whole sequence, for pasting into a bug report.
    static func summarise() {
        lock.lock()
        let snapshot = marks
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        let line = snapshot.map { "\($0.0)=+\(ms($0.1))ms" }.joined(separator: " ")
        log.info("launch summary \(line, privacy: .public)")
        Log.shared.info("launch", line)
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000
            + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
