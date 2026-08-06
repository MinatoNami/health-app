import SwiftUI

/// The landing screen, in Health's idiom: a quiet feed of cards on a grouped
/// background, section headers with a way through to more, and no chrome that
/// is not carrying information.
///
/// Two things went, deliberately:
///
/// **Pull-to-refresh.** With a Sync button on the same screen it was a second
/// control for the same job, and the two did different things — one refreshed
/// charts, the other read HealthKit — which is worse than either alone. Syncing
/// is now one toolbar button that does the whole job.
///
/// **The status ring.** A 132pt dial is a reasonable centrepiece for a screen
/// about syncing; it is the wrong centrepiece for a screen about health. The
/// state it carried has not been dropped — it has been demoted to one line, and
/// promoted back to a full card only when something actually needs attention.
/// Healthy days say almost nothing, which is what makes the bad day visible.
struct StatusView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var authorization: HealthAuthorization
    @EnvironmentObject private var engine: SyncEngine

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !authorization.hasRequested {
                        grantAccessCard
                    }

                    if let banner = SyncBanner.state(
                        phase: engine.phase,
                        lastSyncedAt: engine.settings.lastFullSyncAt,
                        pendingBatches: engine.pendingBatches,
                        uploadEnabled: engine.settings.sink.enabled
                    ) {
                        SyncBanner(state: banner)
                    }

                    highlights
                    trends
                    dataSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Summary")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { syncButton }
            }
            .task { await load() }
            // Anchors only move during a sync, so that is the only moment the
            // coverage line can have changed.
            .onChange(of: engine.phase.isRunning) { _, running in
                if !running { refreshCoverageSummary() }
            }
        }
    }

    private func load() async {
        refreshCoverageSummary()
        if engine.snapshot == nil { await engine.refreshSnapshot() }
        if engine.trends == nil { await engine.refreshTrends() }
    }

    // MARK: - Toolbar

    /// One control, and it does the whole job: read HealthKit, upload, then
    /// refresh what this screen shows.
    private var syncButton: some View {
        Button {
            Task {
                await engine.syncAll(reason: "manual")
                await engine.refreshSnapshot()
                await engine.refreshTrends()
            }
        } label: {
            if engine.phase.isRunning {
                ProgressView()
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(engine.phase.isRunning || !authorization.hasRequested)
        .accessibilityLabel("Sync now")
    }

    // MARK: - Sections

    private var highlights: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Highlights", action: "Insights") {
                services.selectedTab = .insights
            }

            if let snapshot = engine.snapshot, !snapshot.metrics.isEmpty {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.metrics.enumerated()), id: \.element.id) { index, metric in
                            if index > 0 { Divider() }
                            MetricRow(metric: metric)
                        }
                    }
                }

                if let stale = snapshot.metricsNotSyncing, !stale.isEmpty {
                    Card {
                        ForEach(stale) { item in
                            HStack {
                                Label(item.label, systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(item.daysSince ?? 0)d ago")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 3)
                        }
                        Text("Not syncing. A gap is not a zero.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
            } else {
                Card {
                    Text(engine.isSignedIn
                         ? "Nothing to summarise yet. Sync to populate this."
                         : "Sign in on the Settings tab to see your summary.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var trends: some View {
        if let trends = engine.trends, !trends.charts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Trends")

                ForEach(AnalyticsOverview.featured, id: \.self) { slug in
                    if let series = trends.series(slug), !series.points.isEmpty {
                        Card {
                            TrendChart(
                                title: slug.metricDisplayName,
                                series: series,
                                style: series.cumulative == true ? .bars : .line
                            )
                        }
                    }
                }
            }
        }
    }

    /// The exporter's own state, kept off the top of the screen. It matters, but
    /// it is not what someone opens a health app to read — and the banner above
    /// already speaks up when it needs to.
    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Data")

            Card(padded: false) {
                // .plain, or NavigationLink paints the whole row in the accent
                // colour and a list row reads as a button.
                NavigationLink {
                    CoverageDetailView()
                } label: {
                    row("Coverage", value: coverageSummary)
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 16)
                Button {
                    services.selectedTab = .server
                } label: {
                    row("On the server", value: engine.serverStatus.map {
                        "\($0.recordsTotal.formatted()) records"
                    } ?? "—")
                }
                .buttonStyle(.plain)
            }

            Text(lastSyncLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
        }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.body).foregroundStyle(.primary)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// Cached rather than computed in `body`.
    ///
    /// It reads the anchor store — a lock, a dictionary of ~130 states, and a
    /// filter over all of them — and `body` re-runs on every published change
    /// from the sync engine. Recomputing a line that changes once a sync,
    /// hundreds of times a sync, is the kind of cost that never shows up as a
    /// single slow frame and is felt on every one of them.
    @State private var coverageSummary = "—"

    private func refreshCoverageSummary() {
        let states = AnchorStore.shared.all
        guard !states.isEmpty else {
            coverageSummary = "Not tracked yet"
            return
        }
        let now = Date()
        let fresh = states.values.filter {
            guard let last = $0.lastSampleEnd else { return false }
            return now.timeIntervalSince(last) < 24 * 3600
        }.count
        coverageSummary = "\(fresh) of \(states.count) fresh"
    }

    private var lastSyncLine: String {
        guard let last = engine.settings.lastFullSyncAt else { return "Never synced" }
        if Date().timeIntervalSince(last) < 90 { return "Updated just now" }
        return "Updated \(last.formatted(.relative(presentation: .named)))"
    }

    private var grantAccessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Grant Health access to begin", systemImage: "heart.text.square")
                    .font(.headline)
                Text("You'll be asked once per data type. iOS never re-prompts, so enable "
                     + "everything you want on the Metrics tab first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Request Health Access") {
                    Task {
                        await authorization.requestAuthorization()
                        await services.onLaunch()
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Building blocks

/// Health's section header: a bold title, and an optional way through to more.
private struct SectionHeader: View {
    let title: String
    var action: String? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            if let action, let onTap {
                Button(action, action: onTap)
                    .font(.subheadline)
            }
        }
    }
}

private struct Card<Content: View>: View {
    var padded: Bool = true
    @ViewBuilder var content: Content

    init(padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.padded = padded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padded ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
