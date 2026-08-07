import Foundation
import OSLog

/// Background sync fails silently by default, so an exportable in-app log is
/// not a nicety — it's the only way to find out why last night did nothing.
/// Writes to OSLog for Console.app plus a bounded ring buffer the UI can show
/// and the share sheet can export.
final class Log {
    static let shared = Log()

    enum Level: String, Codable {
        case debug, info, warn, error
    }

    struct Entry: Codable, Identifiable {
        var id = UUID()
        var at: Date
        var level: Level
        var category: String
        var message: String

        var display: String {
            "\(Timestamps.iso8601(at))  [\(level.rawValue.uppercased())] \(category): \(message)"
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HealthExporter",
                                category: "sync")
    private let lock = NSLock()
    private var buffer: [Entry] = []
    private let capacity = 2_000
    private let fileURL: URL?

    private init() {
        fileURL = Paths.supportDirectory?.appendingPathComponent("sync.log")
        // Loaded off the main thread, not in this initialiser.
        //
        // `Log.shared` is first touched by the very first line of
        // `didFinishLaunchingWithOptions`, so decoding up to 500 persisted
        // entries here happened before the app had drawn anything — to populate
        // a buffer nothing reads until somebody opens Diagnostics. Entries
        // written before the load lands are merged, not dropped.
        let url = fileURL
        Log.persistQueue.async { [weak self] in
            let restored = Log.loadPersisted(from: url)
            guard !restored.isEmpty, let self else { return }
            self.lock.lock()
            self.buffer = (restored + self.buffer)
                .sorted { $0.at < $1.at }
                .suffix(self.capacity)
                .map { $0 }
            self.lock.unlock()
        }
    }

    func debug(_ category: String, _ message: String) { append(.debug, category, message) }
    func info(_ category: String, _ message: String) { append(.info, category, message) }
    func warn(_ category: String, _ message: String) { append(.warn, category, message) }
    func error(_ category: String, _ message: String) { append(.error, category, message) }

    /// Times a synchronous block and reports it only when it was slow enough to
    /// be felt.
    ///
    /// The sync path runs on the main actor, so any single non-`async` call in it
    /// is a hang of exactly its own duration — `Task.yield()` between calls
    /// cannot break one up. Xcode's hang detector says a hang happened but not
    /// which call did it, and the candidates here are several.
    ///
    /// A threshold rather than logging every call: a page reporting "wrote in
    /// 4ms" three hundred times is what buries the one that took four seconds.
    @discardableResult
    func blocking<T>(
        _ category: String,
        _ label: String,
        over threshold: TimeInterval = 0.25,
        _ body: () throws -> T
    ) rethrows -> T {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        if seconds >= threshold {
            warn(category, String(format: "%@ held the main thread for %.2fs", label, seconds))
        }
        return value
    }

    private func append(_ level: Level, _ category: String, _ message: String) {
        switch level {
        case .debug: logger.debug("\(category, privacy: .public): \(message, privacy: .public)")
        case .info: logger.info("\(category, privacy: .public): \(message, privacy: .public)")
        case .warn: logger.warning("\(category, privacy: .public): \(message, privacy: .public)")
        case .error: logger.error("\(category, privacy: .public): \(message, privacy: .public)")
        }

        lock.lock()
        buffer.append(Entry(at: Date(), level: level, category: category, message: message))
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let snapshot = buffer
        lock.unlock()

        persist(snapshot)
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.reversed()
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        persist([])
    }

    /// Flattened text for the share sheet.
    func exportText() -> String {
        entries.reversed().map(\.display).joined(separator: "\n")
    }

    // MARK: - Persistence

    /// Debounced so a 5,000-sample sync doesn't rewrite the log file 5,000 times.
    private static let persistQueue = DispatchQueue(label: "log.persist", qos: .utility)
    private var lastPersist = Date.distantPast

    private func persist(_ snapshot: [Entry]) {
        guard let fileURL else { return }
        guard Date().timeIntervalSince(lastPersist) > 2 else { return }
        lastPersist = Date()
        Log.persistQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot.suffix(500).map { $0 }) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func loadPersisted(from url: URL?) -> [Entry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
