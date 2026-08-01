import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var authorization: HealthAuthorization
    @EnvironmentObject private var engine: SyncEngine
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("History") {
                    DatePicker("Backfill from",
                               selection: Binding(
                                   get: { engine.settings.backfillStartDate },
                                   set: { engine.settings.backfillStartDate = $0 }
                               ),
                               displayedComponents: .date)
                    Text("Samples older than this are read — so the sync cursor still "
                         + "advances past them — but not exported. Reaching back years "
                         + "mostly buys you per-second heart rate data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Daily rollups") {
                    Stepper(
                        "Re-emit last \(engine.settings.statisticsLookbackDays) days",
                        value: Binding(
                            get: { engine.settings.statisticsLookbackDays },
                            set: { engine.settings.statisticsLookbackDays = $0 }
                        ),
                        in: 1...90
                    )
                    Text("Rollup IDs are deterministic per metric and day, so re-sending "
                         + "recent days is an upsert, not a duplicate. Covers samples that "
                         + "arrive late and change a past day's total.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("HTTP destination") {
                    Toggle("Upload automatically", isOn: Binding(
                        get: { engine.settings.sink.enabled },
                        set: { engine.settings.sink.enabled = $0 }
                    ))
                    TextField("https://your-server/v1/health/batches", text: Binding(
                        get: { engine.settings.sink.baseURL },
                        set: { engine.settings.sink.baseURL = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    SecureField("Bearer token", text: Binding(
                        get: { engine.settings.sink.bearerToken },
                        set: { engine.settings.sink.bearerToken = $0 }
                    ))
                    if engine.settings.sink.enabled && engine.settings.sink.endpoint == nil {
                        Label("Needs a valid https:// URL", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("HTTPS only. Batches that fail to upload stay in the outbox and "
                         + "are retried; permanent failures are parked rather than looped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Permissions") {
                    Button("Open Settings") { authorization.openHealthSettings() }
                    Text("iOS will not re-prompt for a data type once you've decided on "
                         + "it. Settings is the only way to change your mind.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                    Button("Reset Sync Cursors", role: .destructive) {
                        showResetConfirmation = true
                    }
                    Text("Clears every anchor. The next sync re-reads all history from "
                         + "the backfill date, re-emitting records the destination should "
                         + "upsert by UUID.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Reset all sync cursors?",
                                isPresented: $showResetConfirmation,
                                titleVisibility: .visible) {
                Button("Reset", role: .destructive) { engine.resetSyncState() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct DiagnosticsView: View {
    var body: some View {
        List {
            Section("Unresolved identifiers") {
                if MetricCatalog.unresolved.isEmpty {
                    Text("All catalog identifiers resolved on this OS.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("These are in the catalog but unknown to this iOS version, so "
                         + "they're skipped rather than crashing. Listed here so a typo "
                         + "or version gap never silently loses a metric.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(MetricCatalog.unresolved, id: \.self) { name in
                        Text(name).font(.caption.monospaced())
                    }
                }
            }

            Section("Not yet supported") {
                Text("Each needs a bespoke reader rather than the generic sample path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(MetricCatalog.deferredTypes, id: \.self) { item in
                    Text(item).font(.caption)
                }
            }

            Section("Storage") {
                LabeledContent("Pending", value: "\(Outbox.shared.pendingBatches().count) batches")
                LabeledContent("Archived", value: "\(Outbox.shared.archivedBatches().count) batches")
                LabeledContent("Tracked types", value: "\(AnchorStore.shared.all.count)")
            }
        }
        .navigationTitle("Diagnostics")
    }
}
