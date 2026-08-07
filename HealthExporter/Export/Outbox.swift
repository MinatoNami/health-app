import Foundation

/// Durable on-disk spool of NDJSON batch files.
///
/// The queue is the load-bearing part of this design. Reading HealthKit and
/// delivering the result are decoupled deliberately: HealthKit hands you data at
/// unpredictable times, possibly while the device is locked, and the destination
/// may be unreachable. With a spool, a delivery failure is a retry; without one,
/// it's data loss.
///
/// NDJSON — one record per line — rather than a JSON array, because it appends
/// cheaply and streams line-by-line on the far end. A JSON array would force the
/// server to buffer the whole batch to parse it.
/// `@unchecked Sendable` because it is called from off the main actor and the
/// compiler cannot see why that is safe. It is safe for a narrow reason worth
/// keeping true: this class holds no mutable state. The lock below guards the
/// file system, and the JSON encoder is created per call rather than shared —
/// `JSONEncoder` is not safe for concurrent use, so a single stored one would
/// have been a data race the moment writing moved off the main thread.
final class Outbox: @unchecked Sendable {
    static let shared = Outbox()

    struct Batch: Identifiable, Hashable {
        var id: String { url.lastPathComponent }
        var url: URL
        var createdAt: Date
        var byteCount: Int
        var recordCount: Int

        var displayName: String { url.lastPathComponent }
        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        }

        /// Record count is encoded in the filename
        /// (`batch-<date>-<time>-<id>-<count>.ndjson`) rather than derived by
        /// counting newlines. Reading every file to answer "how many records?"
        /// made `pendingCount` cost O(bytes on disk) — with a few hundred spooled
        /// batches that meant hundreds of megabytes re-read on every sync, and
        /// enough concurrent file handles to exhaust the descriptor limit.
        static func recordCount(from url: URL) -> Int {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let last = stem.split(separator: "-").last else { return 0 }
            return Int(last) ?? 0
        }
    }

    private let lock = NSLock()

    /// Built per write rather than stored. `JSONEncoder` is not safe for
    /// concurrent use, and writing now happens off the main actor — one shared
    /// encoder would be a race for the sake of saving an allocation that costs
    /// nothing next to encoding two thousand records.
    ///
    /// No `.convertToSnakeCase`: that strategy also rewrites *dictionary* keys,
    /// which would mangle HealthKit metadata keys like `HKWasUserEntered` into
    /// `h_k_was_user_entered`. Explicit CodingKeys handle the snake_casing.
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// Cap on records per file. Bounded so a single failed upload never blocks a
    /// large backlog, and so memory stays flat during backfill.
    let maxRecordsPerBatch = 5_000

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    private var deviceId: String {
        let store = StateStore<String>(filename: "device-id.json", fallback: "")
        if !store.value.isEmpty { return store.value }
        let fresh = UUID().uuidString
        store.mutate { $0 = fresh }
        return fresh
    }

    // MARK: - Writing

    /// Writes records to a new batch file, splitting if they exceed the cap.
    /// Returns the files created.
    ///
    /// `nonisolated` and `async` on purpose, and the combination is the point:
    /// called with `await` from the main actor, a nonisolated async function runs
    /// on the cooperative pool rather than inheriting the caller's actor. So
    /// encoding a page of two thousand records and writing the file no longer
    /// happens on the main thread, where it was a hang of exactly its own
    /// duration — `Task.yield()` between calls cannot break up a single one.
    ///
    /// Still awaited rather than fired off. The caller advances its sync anchor
    /// immediately afterwards, and an anchor that moves past data which is not
    /// yet on disk turns any failure into silent, undetectable loss.
    @discardableResult
    nonisolated func write(
        _ records: [HealthRecord], windowFrom: Date? = nil, windowTo: Date? = nil
    ) async -> [URL] {
        guard !records.isEmpty, let dir = Paths.outboxDirectory else { return [] }

        let encoder = makeEncoder()
        var written: [URL] = []
        for chunk in records.chunked(into: maxRecordsPerBatch) {
            let batchId = UUID().uuidString
            let header = BatchHeader(
                batchId: batchId,
                deviceId: deviceId,
                recordCount: chunk.count,
                windowFrom: windowFrom.map { Timestamps.iso8601($0) },
                windowTo: windowTo.map { Timestamps.iso8601($0) },
                appVersion: appVersion,
                createdAt: Timestamps.iso8601(Date())
            )

            var payload = Data()
            guard let headerLine = try? encoder.encode(header) else { continue }
            payload.append(headerLine)
            payload.append(0x0A)

            var encoded = 0
            for record in chunk {
                guard let line = try? encoder.encode(record) else {
                    Log.shared.warn("outbox", "Failed to encode record \(record.id)")
                    continue
                }
                payload.append(line)
                payload.append(0x0A)
                encoded += 1
            }
            guard encoded > 0 else { continue }

            let stamp = DateFormatter.fileStamp.string(from: Date())
            let url = dir.appendingPathComponent(
                "batch-\(stamp)-\(batchId.prefix(8))-\(encoded).ndjson"
            )

            if commit(payload, to: url, records: encoded) {
                written.append(url)
            }
        }
        return written
    }

    /// The locked part, kept in a synchronous frame on purpose.
    ///
    /// Taking a lock inside an `async` function is a warning today and an error
    /// in Swift 6, because the compiler cannot tell whether it is held across a
    /// suspension — and a lock held across an `await` deadlocks the moment two
    /// tasks want it. Extracting the critical section means there is no `await`
    /// it could possibly straddle, which is a stronger guarantee than a comment
    /// promising the same thing.
    private func commit(_ payload: Data, to url: URL, records: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try payload.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            Paths.excludeFromBackup(url)
            Log.shared.info("outbox", "Wrote \(records) records to \(url.lastPathComponent)")
            return true
        } catch {
            Log.shared.error("outbox", "Failed writing batch: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Reading

    /// The delivery queue, **oldest first**.
    ///
    /// The order is load-bearing, not cosmetic. The server upserts on a stable
    /// id, and a `stat:<metric>:<day>` rollup is deliberately re-emitted with a
    /// corrected value on later runs — so whichever batch arrives *last* is the
    /// one that wins. Draining newest-first therefore lets a stale total
    /// overwrite a corrected one, which is a silent wrong number rather than a
    /// visible failure. Delivery order has to be causal order.
    ///
    /// This also reads better in the batch list: a queue shown in the order it
    /// will be sent says more than one shown newest-first.
    func pendingBatches() -> [Batch] {
        batches(in: Paths.outboxDirectory)
    }

    /// Delivered batches, **newest first** — a history for a person to read,
    /// not a queue, so the most recent belongs at the top.
    func archivedBatches() -> [Batch] {
        Array(batches(in: Paths.archiveDirectory).reversed())
    }

    private func batches(in dir: URL?) -> [Batch] {
        guard let dir else { return [] }
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "ndjson" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Batch(
                    url: url,
                    createdAt: values?.creationDate ?? .distantPast,
                    byteCount: values?.fileSize ?? 0,
                    recordCount: Batch.recordCount(from: url)
                )
            }
            // Chronological. Callers that want the newest at the top reverse
            // it; the queue must not, so the default is the safe one.
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Cheap: a directory listing, no file opens. This is called at the end of
    /// every drain, so it must not touch file contents.
    private func fileCount(in dir: URL?) -> Int {
        guard let dir,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return 0 }
        return urls.filter { $0.pathExtension == "ndjson" }.count
    }

    // MARK: - Lifecycle

    /// Moves a delivered batch to the archive. Kept rather than deleted so a
    /// re-send is possible without re-reading HealthKit.
    func archive(_ batch: Batch) {
        guard let dir = Paths.archiveDirectory else { return }
        let target = dir.appendingPathComponent(batch.url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: batch.url, to: target)
        } catch {
            Log.shared.error("outbox", "Archive failed for \(batch.displayName): \(error.localizedDescription)")
        }
    }

    func delete(_ batch: Batch) {
        try? FileManager.default.removeItem(at: batch.url)
    }

    /// Empties the outbox. Needed after a bad run leaves duplicate batches
    /// behind — harmless to a server that upserts, but they waste disk and make
    /// the pending count meaningless.
    @discardableResult
    func deleteAllPending() -> Int {
        let batches = pendingBatches()
        for batch in batches { try? FileManager.default.removeItem(at: batch.url) }
        Log.shared.warn("outbox", "Deleted \(batches.count) pending batch file(s)")
        return batches.count
    }

    /// Drops archived batches older than the retention window, then trims the
    /// remainder to a size cap, oldest first.
    ///
    /// Age alone does not bound this. A first sync ships years of history in a
    /// day or two, so "14 days of archive" was measured at **640MB** on a real
    /// phone — copies of data already durably on the server, and a meaningful
    /// slice of the device. The cap is what actually bounds it; the age window
    /// still handles the quiet case. Unbounded local retention of health data
    /// is a liability, not a feature.
    func pruneArchive(olderThan days: Int = 14, maxBytes: Int = 150 * 1024 * 1024) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var remaining: [Batch] = []
        for batch in archivedBatches() {
            if batch.createdAt < cutoff {
                try? FileManager.default.removeItem(at: batch.url)
            } else {
                remaining.append(batch)
            }
        }

        // Newest first, so dropping from the tail keeps the most recently
        // delivered batches — the ones a re-send would plausibly want.
        remaining.sort { $0.createdAt > $1.createdAt }
        var total = 0
        var removed = 0
        for batch in remaining {
            total += batch.byteCount
            if total > maxBytes {
                try? FileManager.default.removeItem(at: batch.url)
                removed += 1
            }
        }
        if removed > 0 {
            Log.shared.info("outbox", "Trimmed \(removed) archived batch(es) over the size cap")
        }
    }

    var pendingCount: Int { fileCount(in: Paths.outboxDirectory) }

    /// The same count, off the caller's thread.
    ///
    /// It is a directory listing, which is cheap right up until the queue is a
    /// few hundred batches deep — which is exactly the situation where the app
    /// is already struggling and least able to afford it on the main thread.
    nonisolated func pendingCountOffMain() async -> Int {
        fileCount(in: Paths.outboxDirectory)
    }

    /// Listing plus a `stat()` per file, off the caller's thread.
    nonisolated func pendingBatchesOffMain() async -> [Batch] {
        batches(in: Paths.outboxDirectory)
    }

    /// Enumerating and deleting, off the caller's thread. Nothing waits on the
    /// result — this is housekeeping, and it can finish whenever it finishes.
    nonisolated func pruneArchiveOffMain() async {
        pruneArchive()
    }
}

extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
