import SwiftUI

/// One metric over time, picked from a row of chips.
///
/// Charts used to live at the bottom of the old Summary tab, below six metric
/// rows and a fold — which meant the screen answered "how am I doing" twice, in
/// two idioms, and you had to scroll past the first to reach the second. Today
/// keeps the verdict; this keeps the shape of it.
///
/// **Gaps are drawn as gaps.** `TrendChart` breaks its line where a day has no
/// reading rather than joining across it. That is not a rendering nicety: a
/// line joined over two nights the watch was off draws sleep that never
/// happened, and this app's whole argument is that it does not do that.
struct TrendsView: View {
    @EnvironmentObject private var engine: SyncEngine

    @State private var slug: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let trends = engine.trends, !available(trends).isEmpty {
                        picker(available(trends))
                        chart(trends)
                        coverageNote(trends)
                    } else {
                        empty
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Ink.ground)
            .scrollContentBackground(.hidden)
            .navigationTitle("Trends")
            .refreshable { await engine.refreshTrends() }
            .task { if engine.trends == nil { await engine.refreshTrends() } }
        }
        .tint(Ink.accent)
    }

    private func available(_ trends: AnalyticsOverview) -> [String] {
        AnalyticsOverview.featured.filter { (trends.series($0)?.points.isEmpty == false) }
    }

    private var selected: String? {
        guard let trends = engine.trends else { return nil }
        let options = available(trends)
        if let slug, options.contains(slug) { return slug }
        return options.first
    }

    private func picker(_ options: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(options, id: \.self) { option in
                    let isOn = option == selected
                    Button { slug = option } label: {
                        Text(MetricStyle.shortLabel(option, fallback: option.metricDisplayName))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(isOn ? Ink.accent : Ink.muted)
                            .frame(minHeight: 34)
                            .padding(.horizontal, 14)
                            .background(isOn ? Ink.accent.opacity(0.13) : Ink.raised)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().strokeBorder(isOn ? Ink.accent : Ink.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private func chart(_ trends: AnalyticsOverview) -> some View {
        if let slug = selected, let series = trends.series(slug) {
            VStack(alignment: .leading, spacing: 16) {
                TrendChart(
                    title: slug.metricDisplayName,
                    series: series,
                    style: series.cumulative == true ? .bars : .line
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    @ViewBuilder
    private func coverageNote(_ trends: AnalyticsOverview) -> some View {
        if let slug = selected, let series = trends.series(slug) {
            let recorded = series.points.count
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 0) {
                    stat(MetricFormat.value(average(series), slug: slug), "AVERAGE")
                    Divider().frame(height: 34).overlay(Ink.divider)
                    stat("\(recorded)", "RECORDED")
                    Divider().frame(height: 34).overlay(Ink.divider)
                    stat(MetricFormat.value(series.points.map(\.value).max(), slug: slug), "HIGHEST")
                }
                .frame(maxWidth: .infinity)
                .cardStyle()

                Text("Days with no reading are left out rather than drawn as zero — joining a line across them would show a value that was never recorded.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func average(_ series: ServerStatus.Series) -> Double? {
        let values = series.points.map(\.value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.figure(18))
                .foregroundStyle(Ink.primary)
            Text(label)
                .font(.system(size: 10.5))
                .tracking(0.5)
                .foregroundStyle(Ink.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(engine.isSignedIn ? "No series yet." : "Sign in to see your trends.")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            Text("Charts appear once the server has a few days of a metric to draw.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.muted)
        }
    }
}
