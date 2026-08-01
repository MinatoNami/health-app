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
        buffer = Log.loadPersisted(from: fileURL)
    }

    func debug(_ category: String, _ message: String) { append(.debug, category, message) }
    func info(_ category: String, _ message: String) { append(.info, category, message) }
    func warn(_ category: String, _ message: String) { append(.warn, category, message) }
    func error(_ category: String, _ message: String) { append(.error, category, message) }

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
