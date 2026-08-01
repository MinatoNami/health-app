import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authorization: HealthAuthorization

    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("Status", systemImage: "waveform.path.ecg") }
            MetricsView()
                .tabItem { Label("Metrics", systemImage: "list.bullet") }
            ExportsView()
                .tabItem { Label("Exports", systemImage: "square.and.arrow.up") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .overlay {
            if !authorization.isAvailable {
                ContentUnavailableView(
                    "HealthKit Unavailable",
                    systemImage: "heart.slash",
                    description: Text("This device does not provide Health data.")
                )
                .background(.background)
            }
        }
    }
}

// MARK: - Status

struct StatusView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var authorization: HealthAuthorization
    @EnvironmentObject private var engine: SyncEngine

    var body: some View {
        NavigationStack {
            List {
                if !authorization.hasRequested {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Grant Health access to begin")
                                .font(.headline)
                            Text("You'll be asked once per data type. iOS will not "
                                 + "re-prompt later, so enable everything you want now — "
                                 + "changes after this have to be made in Settings.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Request Health Access") {
                                Task {
                                    await authorization.requestAuthorization()
                                    await services.onLaunch()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Sync") {
                    LabeledContent("State", value: phaseText)
                    if let summary = engine.lastSummary {
                        LabeledContent("Last run", value: summary)
                    }
                    if let last = engine.settings.lastFullSyncAt {
                        LabeledContent("Completed", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Pending batches", value: "\(engine.pendingBatches)")

                    if case .syncing(let metric, let progress, let total) = engine.phase {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(progress), total: Double(total))
                            Text(metric).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await engine.syncAll(reason: "manual") }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(engine.phase.isRunning || !authorization.hasRequested)
                }

                if case .waitingForUnlock = engine.phase {
                    Section {
                        Label("Waiting for unlock", systemImage: "lock")
                        Text("HealthKit is encrypted while the device is locked, so "
                             + "reads fail rather than return data. This is expected, "
                             + "not an error — the sync resumes automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !staleTypes.isEmpty {
                    Section("Stale metrics") {
                        Text("\(staleTypes.count) metric(s) haven't produced data in 48h. "
                             + "Revoked permissions and background delivery dying after "
                             + "an OS update both look like silence, not errors.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(Array(staleTypes.prefix(10)), id: \.self) { identifier in
                            Text(identifier.healthKitSlug).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Health Exporter")
            .refreshable { engine.refreshCounts() }
        }
    }

    private var staleTypes: [String] {
        AnchorStore.shared.staleTypes()
    }

    private var phaseText: String {
        switch engine.phase {
        case .idle: return "Idle"
        case .waitingForUnlock: return "Waiting for unlock"
        case .syncing(let metric, let p, let t): return "Reading \(metric) (\(p)/\(t))"
        case .delivering(let remaining): return "Delivering (\(remaining) left)"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}
