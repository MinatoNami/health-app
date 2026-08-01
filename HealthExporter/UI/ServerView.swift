import SwiftUI

/// What the destination server holds.
///
/// The rest of the app can only report what it *sent*. This is the one screen
/// that answers "did it actually arrive", which matters because every failure
/// mode here is silent: a revoked token, a certificate that no longer matches
/// the pin, and background delivery quietly dying after an OS update all look
/// exactly like a quiet week.
struct ServerView: View {
    @EnvironmentObject private var engine: SyncEngine

    var body: some View {
        NavigationStack {
            List {
                if !engine.isSignedIn {
                    Section {
                        ContentUnavailableView(
                            "Not signed in",
                            systemImage: "person.crop.circle.badge.xmark",
                            description: Text("Sign in on the Settings tab to see what the server has stored.")
                        )
                    }
                } else if let status = engine.serverStatus {
                    storedSection(status)
                    deliverySection(status)
                    if !status.staleMetrics.isEmpty {
                        staleSection(status)
                    }
                    metricsSection(status)
                    devicesSection(status)
                } else if engine.isLoadingServerStatus {
                    Section { ProgressView("Asking the server…") }
                } else {
                    Section {
                        ContentUnavailableView(
                            "No reading yet",
                            systemImage: "server.rack",
                            description: Text("Pull to refresh.")
                        )
                    }
                }

                if let error = engine.serverStatusError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Server")
            .refreshable { await engine.refreshServerStatus(fresh: true) }
            .task {
                // Cached path on open; pull-to-refresh forces a recount.
                if engine.serverStatus == nil { await engine.refreshServerStatus() }
            }
        }
    }

    // MARK: - Sections

    private func storedSection(_ status: ServerStatus) -> some View {
        Section("Stored") {
            LabeledContent("Records", value: status.recordsTotal.formatted())
            if status.recordsDeleted > 0 {
                LabeledContent("Tombstoned", value: status.recordsDeleted.formatted())
            }
            LabeledContent("Batches accepted", value: status.storedBatches.formatted())
            if status.failedBatches > 0 {
                LabeledContent("Batches failed", value: status.failedBatches.formatted())
                    .foregroundStyle(.orange)
            }
        }
    }

    private func deliverySection(_ status: ServerStatus) -> some View {
        Section("Delivery") {
            if let last = status.lastBatchDate {
                LabeledContent("Last accepted", value: last.formatted(.relative(presentation: .named)))
                LabeledContent("Records in it", value: status.lastBatchRecords.formatted())
            } else {
                Text("The server has not accepted a batch yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Waiting on this phone", value: "\(engine.pendingBatches)")
            if engine.pendingBatches > 0 && !engine.settings.sink.enabled {
                Label("Uploading is off — batches are queuing locally.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func staleSection(_ status: ServerStatus) -> some View {
        Section("Stale on the server") {
            Text("\(status.staleMetrics.count) metric(s) the server hasn't received in 48 hours. "
                 + "That can be normal for something you rarely record — or the first "
                 + "sign that sync stopped for it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(status.staleMetrics.prefix(10)) { metric in
                LabeledContent {
                    Text(metric.latestSampleDate?.formatted(.relative(presentation: .named)) ?? "never")
                        .foregroundStyle(.orange)
                } label: {
                    Text(metric.metricSlug.metricDisplayName).font(.caption)
                }
            }
        }
    }

    private func metricsSection(_ status: ServerStatus) -> some View {
        // Proportional bars rather than a column of counts. Sixty numbers side
        // by side is a table nobody reads; the useful question is "which
        // metrics dominate, and is anything unexpectedly quiet" — and relative
        // length answers that without the reader doing arithmetic. The exact
        // figure stays one tap away in the dashboard.
        Section("By metric") {
            let maximum = max(1, status.metrics.map(\.count).max() ?? 1)
            ForEach(status.metrics.prefix(20)) { metric in
                MetricBar(slug: metric.metricSlug, count: metric.count,
                          maximum: maximum, isStale: metric.isStale)
            }
            if status.metrics.count > 20 {
                Text("+ \(status.metrics.count - 20) more, on the dashboard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }


    private func devicesSection(_ status: ServerStatus) -> some View {
        Section("Devices") {
            ForEach(status.devices) { device in
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.label?.isEmpty == false ? device.label! : device.deviceId)
                        .font(.caption.monospaced())
                    Text("\(device.recordCount.formatted()) records"
                         + (device.appVersion.map { " · v\($0)" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if status.devices.count > 1 {
                Text("More than one device is writing here. Reinstalling the app "
                     + "generates a new device ID, so an old entry usually means a "
                     + "previous install rather than a second phone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
