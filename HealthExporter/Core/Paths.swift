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

    /// Pending batch files.
    ///
    /// These used to live in Documents, with file sharing switched on so they
    /// showed up in the Files app — and in Finder on any Mac the phone trusts —
    /// as a way to retrieve them by hand. That made every queued and archived
    /// batch, up to 150MB and two weeks of raw health data, browsable by
    /// anything with access to the unlocked phone or a paired computer. They sit
    /// beside the anchors and the log now, out of sight; the share sheet on the
    /// Exports tab is the deliberate way to hand one out.
    static let outboxDirectory: URL? = batchDirectory("Outbox")

    /// Batches already handed off successfully, kept for a retention window so
    /// re-sends are possible without re-reading HealthKit.
    static let archiveDirectory: URL? = batchDirectory("Archive")

    /// Batches the server refused for their content. Out of the outbox so one
    /// bad file stops blocking everything behind it, kept rather than deleted
    /// so they can be retried once the server is fixed or upgraded.
    static let rejectedDirectory: URL? = batchDirectory("Rejected")

    /// Resolves all three batch directories now, moving any legacy files out
    /// of Documents. They are otherwise created on first use — which, on a
    /// phone that has not synced yet, is not this launch, and the old folders
    /// would stay visible in Files until it does.
    static func prepareBatchDirectories() {
        _ = outboxDirectory
        _ = archiveDirectory
        _ = rejectedDirectory
    }

    /// A batch directory under `supportDirectory`, with anything a previous
    /// build left in `Documents/<name>` moved across.
    ///
    /// Moved, not copied or abandoned: the outbox is the only copy of data whose
    /// anchors have already advanced, so leaving it behind in the old folder
    /// would be silent loss. Each move is a rename on the same volume and works
    /// while the phone is locked, and a file that fails to move stays where it
    /// was for the next launch to try again rather than being deleted.
    private static func batchDirectory(_ name: String) -> URL? {
        guard let base = supportDirectory else { return nil }
        let dir = base.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        excludeFromBackup(dir)

        if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let moved = moveContents(of: documents.appendingPathComponent(name, isDirectory: true),
                                     into: dir)
            if moved > 0 {
                Log.shared.info("paths", "Moved \(moved) file(s) from Documents/\(name) out of the Files app")
            }
        }
        return dir
    }

    /// Moves every file in `legacy` into `dir`, then removes `legacy` once it is
    /// empty. Returns how many files moved.
    static func moveContents(of legacy: URL, into dir: URL) -> Int {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        var moved = 0
        for file in files {
            let target = dir.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                // Already moved by an earlier launch that died before removing
                // the original. Batch names carry a UUID, so same name is same
                // batch.
                try? fm.removeItem(at: file)
            } else if (try? fm.moveItem(at: file, to: target)) != nil {
                moved += 1
            }
        }
        if (try? fm.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true {
            try? fm.removeItem(at: legacy)
        }
        return moved
    }

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
        // Protected at rest, like the spooled batches are. These files hold
        // health figures — a cached summary, the date of the newest sample per
        // metric — and the only reason they were not covered before is that the
        // first one written happened to be a settings struct.
        try? data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        Paths.excludeFromBackup(target)
    }

    func reset() {
        mutate { $0 = fallback }
    }
}
