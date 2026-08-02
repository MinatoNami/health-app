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

    /// Only the days that actually place on the axis. Everything on this screen
    /// reads from this rather than `series.points`, so a point the chart cannot
    /// draw is also not counted in the summary or the headline figure.
    private var points: [ServerStatus.Series.Point] {
        series.points.filter { $0.parsedDay != nil }
    }

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
                if let latest = points.last {
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

            if points.isEmpty {
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
        Chart(points) { point in
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

    /// Every path here must return a range that is non-empty and correctly
    /// ordered. A zero-height domain makes Charts give up on deriving a mark
    /// dimension ("falling back to a fixed dimension size"), and an inverted one
    /// traps outright in `ClosedRange`. Both are reachable from ordinary data: a
    /// metric that reads the same every day is flat, and a metric that is zero
    /// every day — `sleep_analysis` on a phone that does not track sleep — is
    /// both flat and zero.
    private var domain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...1 }

        if style == .bars {
            // A bar is read against zero, so the domain has to contain zero
            // whichever side of it the data falls on.
            let lower = Swift.min(low, 0)
            let upper = Swift.max(high * 1.1, 0)
            return lower < upper ? lower...upper : lower...(lower + 1)
        }

        guard low < high else {
            // Flat series: no span of its own, so give it a band to sit in.
            let pad = Swift.max(abs(low) * 0.1, 0.5)
            return (low - pad)...(low + pad)
        }
        let pad = (high - low) * 0.15
        return (low - pad)...(high + pad)
    }

    private var accessibilitySummary: String {
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max(), let latest = values.last else {
            return "\(title): no data"
        }
        return "\(title) over \(points.count) days. "
            + "Low \(format(low)), high \(format(high)), latest \(format(latest))."
    }

    private func format(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 10_000 { return String(format: "%.1fK", value / 1000) }
        if magnitude >= 100 { return value.formatted(.number.precision(.fractionLength(0))) }
        return value.formatted(.number.precision(.fractionLength(magnitude < 10 ? 1 : 0)))
    }
}
