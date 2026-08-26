import SwiftUI

/// Metrics and Server, merged — and Settings hung off the end of it.
///
/// Three of five tabs used to be plumbing: which HealthKit types are on, what
/// the server holds, and everything else. All three answer one question — *is
/// the machine working* — and the bottom bar is the most expensive real estate
/// in the app to spend on it. They are one tab now, and the tab bar is four.
///
/// What leads the screen is deliberately not the record count. It is whatever
/// has *stopped arriving*, because that is the failure this whole system is
/// built to catch: nothing errors, the numbers just quietly stop.
struct DataView: View {
    @EnvironmentObject private var engine: SyncEngine

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    staleSection
                    sources
                    server
                    settingsRow
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Ink.ground)
            .scrollContentBackground(.hidden)
            .navigationTitle("Data")
            .refreshable { await engine.refreshServerStatus(fresh: true) }
            .task {
                if engine.serverStatus == nil { await engine.refreshServerStatus() }
            }
        }
        .tint(Ink.accent)
    }

    /// Every metric the server has not heard from, not just the headline six.
    ///
    /// `snapshot.metricsNotSyncing` covers only the metrics a snapshot leads
    /// with — right for Today, wrong here. This screen is where you come to
    /// find out what stopped, so it reads the server's own full list.
    private var stale: [ServerStatus.Metric] {
        engine.serverStatus?.staleMetrics ?? []
    }

    @ViewBuilder
    private var staleSection: some View {
        if !stale.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                staleCallout(stale.prefix(3).map(\.metricSlug.metricDisplayName))
                if stale.count > 3 {
                    Text("+ \(stale.count - 3) more not seen in 48 hours")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.faint)
                }
            }
        }
    }

    private func staleCallout(_ names: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 17))
                .foregroundStyle(Ink.absent)
            VStack(alignment: .leading, spacing: 3) {
                Text(names.joined(separator: ", "))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.absentInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Not seen in 48 hours. Normal for something you rarely record — or the first sign sync stopped for it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Ink.absent.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Ink.absent.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Sources

    private var sources: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("What this phone reads").sectionLabelStyle()
            NavigationLink {
                MetricsView()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Metric groups")
                            .font(.system(size: 14.5))
                            .foregroundStyle(Ink.primary)
                        Text(enabledSummary)
                            .font(.figure(11.5, weight: .regular))
                            .foregroundStyle(Ink.faint)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.faint)
                }
                .frame(minHeight: 54)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            }
            .buttonStyle(.plain)
        }
    }

    private var enabledSummary: String {
        let count = engine.snapshot?.metrics.count ?? 0
        return count > 0 ? "\(count) analysable metrics arriving" : "tap to choose what is read"
    }

    // MARK: - Server

    private var server: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("On your server").sectionLabelStyle()
            VStack(spacing: 0) {
                if let status = engine.serverStatus {
                    statRow("Records stored", status.recordsTotal.formatted(), first: true)
                    statRow("Last upload", status.lastBatchDate.map {
                        $0.formatted(date: .omitted, time: .shortened)
                    } ?? "never")
                    statRow(
                        "Waiting to send",
                        "\(engine.pendingBatches)",
                        tint: engine.pendingBatches == 0 ? Ink.measured : Ink.absent
                    )
                } else if engine.isLoadingServerStatus {
                    statRow("Asking the server…", "", first: true)
                } else {
                    statRow(engine.isSignedIn ? "Pull to refresh" : "Not signed in", "", first: true)
                }
            }
            .cardStyle()

            // The full per-metric breakdown, the stale list and the device list
            // are still worth having — they are just not worth a tab.
            NavigationLink {
                ServerView()
            } label: {
                HStack {
                    Text("Everything the server holds")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Ink.muted)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.faint)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func statRow(_ title: String, _ value: String, first: Bool = false, tint: Color? = nil) -> some View {
        VStack(spacing: 0) {
            if !first { Divider().overlay(Ink.divider) }
            HStack {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Text(value)
                    .font(.figure(13.5))
                    .foregroundStyle(tint ?? Ink.primary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
        }
    }

    // MARK: - Settings

    private var settingsRow: some View {
        NavigationLink {
            SettingsView()
        } label: {
            HStack {
                Text("Account, brief & diagnostics")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.faint)
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 16)
            .background(Ink.raised)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Ink.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
