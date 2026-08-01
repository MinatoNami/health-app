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
final class Outbox {
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
    }

    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // No `.convertToSnakeCase`: that strategy also rewrites *dictionary*
        // keys, which would mangle HealthKit metadata keys like
        // `HKWasUserEntered` into `h_k_was_user_entered`. Explicit CodingKeys
        // handle the snake_casing instead.
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

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
    @discardableResult
    func write(_ records: [HealthRecord], windowFrom: Date? = nil, windowTo: Date? = nil) -> [URL] {
        guard !records.isEmpty, let dir = Paths.outboxDirectory else { return [] }

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
            let url = dir.appendingPathComponent("batch-\(stamp)-\(batchId.prefix(8)).ndjson")

            lock.lock()
            do {
                try payload.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
                Paths.excludeFromBackup(url)
                written.append(url)
                Log.shared.info("outbox", "Wrote \(encoded) records to \(url.lastPathComponent)")
            } catch {
                Log.shared.error("outbox", "Failed writing batch: \(error.localizedDescription)")
            }
            lock.unlock()
        }
        return written
    }

    // MARK: - Reading

    func pendingBatches() -> [Batch] {
        batches(in: Paths.outboxDirectory)
    }

    func archivedBatches() -> [Batch] {
        batches(in: Paths.archiveDirectory)
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
                    recordCount: Outbox.countLines(url) - 1 // minus the header line
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Counts newlines without loading the file into memory.
    private static func countLines(_ url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        var count = 0
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            count += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        return count
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

    /// Drops archived batches older than the retention window. Unbounded local
    /// retention of health data is a liability, not a feature.
    func pruneArchive(olderThan days: Int = 14) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for batch in archivedBatches() where batch.createdAt < cutoff {
            try? FileManager.default.removeItem(at: batch.url)
        }
    }

    var pendingCount: Int { pendingBatches().count }
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
