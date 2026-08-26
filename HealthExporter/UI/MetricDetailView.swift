import SwiftUI

/// One metric, and how much of it was actually measured.
///
/// The last section is the one that matters and the one no comparable app
/// ships: **what this cannot tell you**. Whoop reports a recovery percentage
/// and never mentions the two nights the watch was off; this screen leads with
/// the figure, then spends most of its height qualifying it.
///
/// That is not hedging for its own sake. The server already computes the
/// coverage and the confidence reason — `grade_confidence` returns "4 of 7 days
/// have data" precisely so a reader can check the claim rather than trust it —
/// and until this screen existed none of it was rendered anywhere.
struct MetricDetailView: View {
    let comparison: HealthSnapshot.Comparison

    @EnvironmentObject private var services: AppServices

    private var isSleep: Bool { comparison.metricSlug == "sleep_analysis" }
    private var noun: String { isSleep ? "nights" : "days" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                figure
                coverageCard
                limits
                askRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(Ink.ground)
        .scrollContentBackground(.hidden)
        .navigationTitle(comparison.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Figure

    private var figure: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MetricFormat.value(comparison.current.value, slug: comparison.metricSlug))
                    .font(.figure(50))
                    .kerning(-1.4)
                    .foregroundStyle(Ink.primary)
                Text(unitPhrase)
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.muted)
            }
            if comparison.isUsable, comparison.changePct != nil {
                (
                    Text(MetricFormat.change(comparison.changePct))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(tint)
                    + Text(" on your 28-day average of \(MetricFormat.value(comparison.baseline.value, slug: comparison.metricSlug)) \(MetricStyle.unit(comparison.unit, slug: comparison.metricSlug))")
                        .font(.system(size: 14))
                        .foregroundColor(Ink.muted)
                )
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(comparison.confidenceReason)
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var unitPhrase: String {
        let unit = MetricStyle.unit(comparison.unit, slug: comparison.metricSlug)
        if isSleep { return "\(unit) / night" }
        if comparison.metricSlug == "step_count" { return "steps / day" }
        return unit
    }

    private var tint: Color {
        switch comparison.tone {
        case .good: return Ink.measured
        case .watch: return Ink.absent
        case .neutral: return Ink.faint
        }
    }

    // MARK: - Coverage

    private var coverageCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Coverage").sectionLabelStyle()
                Spacer()
                ConfidencePill(confidence: comparison.confidence)
            }

            CoverageStrip(
                validDays: comparison.current.validDays,
                windowDays: comparison.current.windowDays,
                thickness: 34,
                spacing: 5,
                segmentWidth: nil
            )

            // The server's own words, not a restatement. It already explains
            // *why* a grade is what it is, and paraphrasing that on the client
            // is how the phone and the dashboard start disagreeing.
            Text(comparison.confidenceReason.prefix(1).capitalized + comparison.confidenceReason.dropFirst() + ".")
                .font(.system(size: 12.5))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("The 28-day baseline has \(comparison.baseline.validDays) of \(comparison.baseline.windowDays).")
                .font(.system(size: 12.5))
                .foregroundStyle(Ink.faint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - Limits

    private var limits: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this cannot tell you").sectionLabelStyle()
            ForEach(caveats, id: \.self) { caveat in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Ink.faint)
                        .frame(width: 4, height: 4)
                        .padding(.top, 8)
                    Text(caveat)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Per metric, because the honest caveat for sleep is not the honest caveat
    /// for steps. The last one is shared and is the one this whole app is built
    /// around: a gap is not a zero.
    private var caveats: [String] {
        var out: [String] = []
        switch comparison.metricSlug {
        case "sleep_analysis":
            out.append("Whether you were rested. This is time asleep, not sleep quality.")
        case "step_count":
            out.append("Cycling, swimming and rowing. None of them move this number.")
        case "apple_exercise_time":
            out.append("How hard the effort was. Minutes count time, not intensity.")
        case "resting_heart_rate", "heart_rate_variability_sdnn":
            out.append("Why it changed. Sleep, alcohol, illness and stress all move this, and none of them are recorded here.")
        case "body_mass":
            out.append("What the change is made of. Water, food and muscle all weigh.")
        default:
            break
        }
        let missing = comparison.current.windowDays - comparison.current.validDays
        if missing > 0 {
            out.append("\(missing) \(missing == 1 ? String(noun.dropLast()) : noun) with no reading. Those are absent, not low.")
        } else {
            out.append("A \(noun.dropLast()) the sensor was not worn. Those would be absent, not low.")
        }
        return out
    }

    // MARK: - Ask

    private var askRow: some View {
        Button {
            services.selectedTab = .insights
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.accent)
                Text("Ask about this week's \(comparison.label.lowercased())")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.faint)
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
