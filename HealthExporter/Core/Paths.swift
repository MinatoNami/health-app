import Foundation

enum Paths {
    /// Private app state: anchors, checkpoints, logs. Not user-visible.
    static let supportDirectory: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("HealthExporter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        excludeFromBackup(dir)
        return dir
    }()

    /// Pending batch files. Exposed in Documents so they show up in the Files
    /// app under On My iPhone, which makes manual retrieval possible without
    /// going through the share sheet.
    static let outboxDirectory: URL? = {
        guard let base = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        excludeFromBackup(dir)
        return dir
    }()

    /// Batches already handed off successfully, kept for a retention window so
    /// re-sends are possible without re-reading HealthKit.
    static let archiveDirectory: URL? = {
        guard let base = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        excludeFromBackup(dir)
        return dir
    }()

    /// App Store Review Guideline 5.1.3 prohibits storing health information in
    /// iCloud, and iCloud Backup counts. Exclude every directory that can hold
    /// health data or anything derived from it.
    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}

/// Small file-backed store for Codable app state.
///
/// Deliberately not `UserDefaults`: a plist with weaker data protection is the
/// wrong home for anything derived from health data, and defaults get synced
/// and backed up in ways that are awkward to audit.
final class StateStore<T: Codable>: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var cached: T?
    private let fallback: T

    init(filename: String, fallback: T) {
        self.url = Paths.supportDirectory?.appendingPathComponent(filename)
        self.fallback = fallback
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            cached = fallback
            return fallback
        }
        cached = decoded
        return decoded
    }

    func mutate(_ block: (inout T) -> Void) {
        guard let (snapshot, target) = apply(block) else { return }
        Self.persist(snapshot, to: target)
    }

    /// `mutate`, with the file write moved off the caller's thread.
    ///
    /// The in-memory update still happens synchronously, so anything that reads
    /// `value` on the next line sees the new state. Only the encode-and-write is
    /// deferred — which for the anchor store is the whole file, every type, once
    /// per page of a sync, and it was running on the main actor.
    ///
    /// Awaited rather than detached: callers persist an anchor precisely because
    /// they are about to rely on it having been persisted.
    func mutateOffMain(_ block: (inout T) -> Void) async {
        guard let (snapshot, target) = apply(block) else { return }
        await Task.detached(priority: .utility) {
            Self.persist(snapshot, to: target)
        }.value
    }

    /// The mutation itself. Returns what needs writing, or nil if there is no
    /// file backing this store.
    private func apply(_ block: (inout T) -> Void) -> (T, URL)? {
        lock.lock()
        var current = cached ?? {
            guard let url, let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return decoded
        }()
        block(&current)
        cached = current
        let snapshot = current
        let target = url
        lock.unlock()

        guard let target else { return nil }
        return (snapshot, target)
    }

    private static func persist(_ snapshot: T, to target: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: target, options: .atomic)
        Paths.excludeFromBackup(target)
    }

    func reset() {
        mutate { $0 = fallback }
    }
}
