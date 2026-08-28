import SwiftUI

/// Icon, tint and wording for a metric, following Health's own grouping.
///
/// Health colours by *category* rather than per metric — everything cardiac is
/// red, everything respiratory is teal, body measurements are purple — which is
/// why resting heart rate and HRV share a colour rather than each getting their
/// own. Copying that is not imitation for its own sake: it means a glance at
/// this screen and a glance at Health agree about what kind of thing each row
/// is, and there is no second colour language to learn.
enum MetricStyle {

    static func symbol(for slug: String) -> String {
        switch slug {
        case "step_count": return "figure.walk"
        case "distance_walking_running": return "figure.walk.motion"
        case "active_energy_burned": return "flame.fill"
        case "apple_exercise_time": return "figure.run"
        case "heart_rate", "resting_heart_rate", "walking_heart_rate_average": return "heart.fill"
        case "heart_rate_variability_sdnn": return "waveform.path.ecg"
        case "sleep_analysis": return "bed.double.fill"
        case "body_mass", "body_fat_percentage": return "figure"
        case "respiratory_rate": return "lungs.fill"
        case "oxygen_saturation": return "drop.fill"
        default: return "chart.line.uptrend.xyaxis"
        }
    }

    static func tint(for slug: String) -> Color {
        switch slug {
        case "step_count", "distance_walking_running", "active_energy_burned":
            return .orange
        case "apple_exercise_time":
            return .green
        case "heart_rate", "resting_heart_rate", "walking_heart_rate_average",
             "heart_rate_variability_sdnn":
            return .red
        case "sleep_analysis":
            return Color(.systemTeal)
        case "respiratory_rate", "oxygen_saturation":
            return Color(.systemTeal)
        case "body_mass", "body_fat_percentage":
            return .purple
        default:
            return .accentColor
        }
    }

    /// Units as Health writes them. "count" and "count/min" are HealthKit's
    /// internal spellings and belong nowhere near a summary screen.
    static func unit(_ raw: String, slug: String) -> String {
        switch slug {
        case "step_count": return "steps"
        case "resting_heart_rate", "heart_rate", "walking_heart_rate_average": return "BPM"
        case "apple_exercise_time": return "min"
        case "sleep_analysis": return "hr"
        case "respiratory_rate": return "br/min"
        default: return raw == "count" ? "" : raw
        }
    }

    /// The name a person would say. Delegates to `MetricName` so the summary,
    /// the coverage grid, the server list and the metric picker cannot end up
    /// calling the same measurement three different things.
    static func title(_ label: String, slug: String) -> String {
        MetricName.display(slug)
    }
}

/// One metric, in Health's row shape: a tinted title line with the period on
/// the right, and the value beneath it at reading size.
///
/// The delta is deliberately quiet. On the Insights screen the comparison is the
/// point and it earns colour; here the value is the point, and six coloured
/// percentages down the card turn a summary into a scoreboard.
struct MetricRow: View {
    let metric: HealthSnapshot.Comparison

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: MetricStyle.symbol(for: metric.metricSlug))
                    .font(.caption.weight(.semibold))
                Text(MetricStyle.title(metric.label, slug: metric.metricSlug))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(period)
                    .font(.caption)
                    .foregroundStyle(Ink.muted)
            }
            .foregroundStyle(MetricStyle.tint(for: metric.metricSlug))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                Text(MetricStyle.unit(metric.unit, slug: metric.metricSlug))
                    .font(.subheadline)
                    .foregroundStyle(Ink.muted)
                Spacer(minLength: 8)
                if let change = deltaText {
                    Text(change)
                        .font(.caption)
                        .foregroundStyle(Ink.muted)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var period: String {
        metric.metricSlug == "sleep_analysis" ? "7-night avg" : "7-day avg"
    }

    private var value: String {
        guard let value = metric.current.value else { return "—" }
        let magnitude = abs(value)
        if magnitude >= 10_000 { return value.formatted(.number.precision(.fractionLength(0))) }
        if magnitude >= 100 { return value.formatted(.number.precision(.fractionLength(0))) }
        return value.formatted(.number.precision(.fractionLength(magnitude < 10 ? 1 : 0)))
    }

    private var deltaText: String? {
        guard metric.isUsable, let pct = metric.changePct, abs(pct) >= 1 else { return nil }
        return "\(pct > 0 ? "↑" : "↓")\(Int(abs(pct).rounded()))% vs 28-day"
    }
}

/// Number formatting for the redesigned screens.
///
/// Split from `MetricStyle` because it is about *figures*, not about a metric's
/// identity — and because the same rounding has to hold on the Today row, the
/// detail hero and the steady chip. Three copies of "one decimal under ten"
/// would drift, and a figure that reads 7.0 on one screen and 7 on the next
/// looks like two different numbers.
enum MetricFormat {

    /// A value at a magnitude a person reads, with the thousands compressed.
    ///
    /// 12,270 steps becomes "12.3k". The exact figure is not the point on a
    /// summary row — the size of it is — and five digits crowd out the label
    /// beside them.
    static func value(_ value: Double?, slug: String) -> String {
        guard let value else { return "—" }
        let magnitude = abs(value)

        // Steps and distance are the only things that reach five digits, and
        // they are also the only ones nobody quotes exactly.
        if slug == "step_count", magnitude >= 10_000 {
            return (value / 1000).formatted(.number.precision(.fractionLength(1))) + "k"
        }
        if magnitude >= 1_000 { return value.formatted(.number.precision(.fractionLength(0))) }
        if magnitude >= 100 { return value.formatted(.number.precision(.fractionLength(0))) }
        return value.formatted(.number.precision(.fractionLength(magnitude < 10 ? 1 : 0)))
    }

    /// A percentage change, signed. Returns "—" below one percent rather than
    /// "0%", which reads as a measurement rather than as an absence of one.
    static func change(_ pct: Double?) -> String {
        guard let pct, abs(pct) >= 1 else { return "—" }
        return (pct > 0 ? "+" : "−") + "\(Int(abs(pct).rounded()))%"
    }
}

extension MetricStyle {
    /// A name that fits in a chip. "Heart Rate Variability" is three words too
    /// long for a 90pt pill, and truncating it mid-word reads as a bug.
    static func shortLabel(_ slug: String, fallback: String) -> String {
        switch slug {
        case "resting_heart_rate": return "Resting HR"
        case "heart_rate_variability_sdnn": return "HRV"
        case "walking_heart_rate_average": return "Walking HR"
        case "apple_exercise_time": return "Exercise"
        case "distance_walking_running": return "Distance"
        case "active_energy_burned": return "Energy"
        case "oxygen_saturation": return "Blood O₂"
        case "body_fat_percentage": return "Body fat"
        case "sleep_analysis": return "Sleep"
        case "body_mass": return "Weight"
        default: return fallback
        }
    }
}
