import Charts
import SwiftUI

/// Charts of what the server actually holds, drawn from the same analytics API
/// the web dashboard uses — so the phone and the browser can never disagree.
///
/// One series per chart, no legend, no value on every point: the shape is the
/// content. Exact figures live in the dashboard's table view.
struct TrendChart: View {
    let title: String
    let series: ServerStatus.Series
    let style: Style

    enum Style { case bars, line }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if series.mayDoubleCount {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Some days are estimated from raw samples")
                }
                Spacer()
                if let latest = series.points.last {
                    // One number, not a column of them: the current value is
                    // the only figure worth putting on a summary chart.
                    Text(format(latest.value))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    + Text(series.unit.map { " \($0)" } ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if series.points.isEmpty {
                Text("No data in this range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 74)
            } else {
                chart
                    .frame(height: 74)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .accessibilityLabel(accessibilitySummary)
            }
        }
    }

    // Plotted against `point.day`, not the raw date string. A string x-axis is
    // categorical: every point gets equal width, so a metric recorded on 6 days
    // out of 30 draws as 6 evenly spaced readings and silently implies daily
    // sampling. On a date axis the gaps are visible, which is the truth.
    @ViewBuilder
    private var chart: some View {
        Chart(series.points) { point in
            switch style {
            case .bars:
                BarMark(
                    x: .value("Day", point.day),
                    y: .value(title, point.value)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(2)
            case .line:
                // yStart pinned to the domain floor, not left to default to
                // zero. A discrete metric's axis does not start at zero, so an
                // area anchored there is drawn outside the plot rectangle and
                // bleeds over whatever sits below the chart.
                AreaMark(
                    x: .value("Day", point.day),
                    yStart: .value("Baseline", domain.lowerBound),
                    yEnd: .value(title, point.value)
                )
                .foregroundStyle(Color.accentColor.opacity(0.12).gradient)
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Day", point.day),
                    y: .value(title, point.value)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
        }
        // Discrete metrics like heart rate never approach zero, so a
        // zero-anchored axis would flatten the variation that matters.
        .chartYScale(domain: domain)
        // Nothing may paint outside the plot rectangle, whatever a future mark
        // decides its baseline is.
        .chartPlotStyle { $0.clipped() }
    }

    private var domain: ClosedRange<Double> {
        let values = series.points.map(\.value)
        guard let min = values.min(), let max = values.max(), min != max else {
            return 0...(values.first.map { $0 * 1.2 } ?? 1)
        }
        if style == .bars { return 0...(max * 1.1) }
        let pad = (max - min) * 0.15
        return (min - pad)...(max + pad)
    }

    private var accessibilitySummary: String {
        let values = series.points.map(\.value)
        guard let low = values.min(), let high = values.max(), let latest = values.last else {
            return "\(title): no data"
        }
        return "\(title) over \(series.points.count) days. "
            + "Low \(format(low)), high \(format(high)), latest \(format(latest))."
    }

    private func format(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 10_000 { return String(format: "%.1fK", value / 1000) }
        if magnitude >= 100 { return value.formatted(.number.precision(.fractionLength(0))) }
        return value.formatted(.number.precision(.fractionLength(magnitude < 10 ? 1 : 0)))
    }
}
