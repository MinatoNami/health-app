import SwiftUI

/// The home screen. One question first — is this working? — then shape, then
/// detail. Numbers are deliberately sparse: a wall of counts is how a status
/// screen stops being read, and the Server tab already carries the figures for
/// when they are actually wanted.
struct StatusView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var authorization: HealthAuthorization
    @EnvironmentObject private var engine: SyncEngine

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if !authorization.hasRequested {
                        grantAccessCard
                    }

                    SyncStatusCard(
                        phase: engine.phase,
                        lastSyncedAt: engine.settings.lastFullSyncAt,
                        pendingBatches: engine.pendingBatches,
                        uploadEnabled: engine.settings.sink.enabled
                    )

                    Button {
                        Task { await engine.syncAll(reason: "manual") }
                    } label: {
                        Label(engine.phase.isRunning ? "Syncing…" : "Sync Now",
                              systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(engine.phase.isRunning || !authorization.hasRequested)

                    if let trends = engine.trends, !trends.charts.isEmpty {
                        trendsSection(trends)
                    }

                    coverageSection

                    if !engine.settings.sink.enabled && engine.pendingBatches > 0 {
                        uploadOffNotice
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Health Exporter")
            .refreshable {
                engine.refreshCounts()
                await engine.refreshTrends()
            }
            .task {
                if engine.trends == nil { await engine.refreshTrends() }
            }
        }
    }

    // MARK: - Sections

    private var grantAccessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Grant Health access to begin", systemImage: "heart.text.square")
                .font(.headline)
            Text("You'll be asked once per data type. iOS never re-prompts, so "
                 + "enable everything you want on the Metrics tab first.")
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func trendsSection(_ trends: AnalyticsOverview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Last 30 days")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("from your server")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(AnalyticsOverview.featured, id: \.self) { slug in
                if let series = trends.series(slug), !series.points.isEmpty {
                    TrendChart(
                        title: Self.titles[slug] ?? slug.replacingOccurrences(of: "_", with: " "),
                        series: series,
                        style: series.cumulative == true ? .bars : .line
                    )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var coverageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Metric coverage")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("tap a cell")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            let states = AnchorStore.shared.all
            if states.isEmpty {
                Text("Nothing tracked yet. Run a sync to populate this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                CoverageGrid(states: states)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var uploadOffNotice: some View {
        Label("Uploading is off — batches are queuing on this phone.",
              systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private static let titles = [
        "step_count": "Steps",
        "heart_rate": "Heart rate",
        "active_energy_burned": "Active energy",
        "sleep_analysis": "Sleep",
    ]
}
