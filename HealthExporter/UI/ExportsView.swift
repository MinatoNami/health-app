import SwiftUI

/// Batch files, with a share sheet. This is the v1 delivery mechanism: the file
/// on disk *is* the export.
struct ExportsView: View {
    @EnvironmentObject private var engine: SyncEngine
    @State private var pending: [Outbox.Batch] = []
    @State private var archived: [Outbox.Batch] = []
    @State private var previewBatch: Outbox.Batch?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("NDJSON — one record per line. Streams cleanly and appends "
                         + "cheaply, so a server can process a batch without buffering "
                         + "it whole.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Pending (\(pending.count))") {
                    if pending.isEmpty {
                        Text("Nothing queued").foregroundStyle(.secondary)
                    }
                    ForEach(pending) { batch in
                        BatchRow(batch: batch) { previewBatch = batch }
                    }
                    if !pending.isEmpty {
                        ShareLink(items: pending.map(\.url)) {
                            Label("Share All Pending", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if !archived.isEmpty {
                    Section("Delivered (\(archived.count))") {
                        ForEach(archived) { batch in
                            BatchRow(batch: batch) { previewBatch = batch }
                        }
                    }
                }

                Section {
                    ShareLink(item: Log.shared.exportText(),
                              preview: SharePreview("Sync log")) {
                        Label("Export Sync Log", systemImage: "doc.text")
                    }
                    NavigationLink("View Log") { LogView() }
                }
            }
            .navigationTitle("Exports")
            .onAppear(perform: reload)
            .refreshable { reload() }
            .sheet(item: $previewBatch) { batch in
                BatchPreview(batch: batch)
            }
        }
    }

    private func reload() {
        pending = Outbox.shared.pendingBatches()
        archived = Outbox.shared.archivedBatches()
        engine.refreshCounts()
    }
}

private struct BatchRow: View {
    let batch: Outbox.Batch
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(batch.displayName).font(.callout.monospaced())
                Text("\(batch.recordCount) records · \(batch.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions {
            ShareLink(item: batch.url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

/// First lines of a batch, so the format can be eyeballed on-device without
/// pulling the file off the phone first.
private struct BatchPreview: View {
    let batch: Outbox.Batch
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Loading…"

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(batch.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: batch.url)
                }
            }
            .task { text = Self.head(of: batch.url) }
        }
    }

    private static func head(of url: URL, lines: Int = 40) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "Unreadable" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 128 * 1024)) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").prefix(lines).joined(separator: "\n\n")
    }
}

struct LogView: View {
    @State private var entries: [Log.Entry] = []

    var body: some View {
        List {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message).font(.caption)
                    Text("\(entry.category) · \(entry.at.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(entry.level == .error ? Color.red.opacity(0.08) : nil)
            }
        }
        .navigationTitle("Log")
        .toolbar {
            Button("Clear") {
                Log.shared.clear()
                entries = []
            }
        }
        .onAppear { entries = Log.shared.entries }
    }
}
