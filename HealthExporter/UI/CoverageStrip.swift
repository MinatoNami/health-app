import SwiftUI

/// One segment per day in a window, filled where that day has data.
///
/// This is the redesign's whole argument in one control. The server already
/// returns `valid_days` and `window_days` on every comparison — the figure that
/// separates "you slept 7.0 hours" from "you slept 7.0 hours on the two nights
/// the watch was on" — and until now nothing on the phone drew it. Whoop shows
/// a recovery percentage and never mentions the nights it is missing; this is
/// the error bar those apps do not ship.
///
/// It is not a progress bar. Filling 5 of 7 is not 71% of the way to anything;
/// it is five days of evidence and two of silence, and the gaps are drawn as
/// gaps for the same reason a line chart must not join across them.
struct CoverageStrip: View {
    let validDays: Int
    let windowDays: Int

    /// Segment height. The inline strip under the lead sentence is 4pt; the
    /// evidence rows beside a figure use 3.
    var thickness: CGFloat = 4
    var spacing: CGFloat = 3
    /// Fixed segment width, or nil to divide the available width.
    var segmentWidth: CGFloat? = 15

    private var filled: Int { max(0, min(validDays, windowDays)) }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<max(windowDays, 1), id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index < filled ? Ink.measured : Ink.hairline)
                    .frame(width: segmentWidth, height: thickness)
                    .frame(maxWidth: segmentWidth == nil ? .infinity : nil)
            }
        }
        // One element, one sentence. Seven separately-focusable capsules is a
        // VoiceOver reading of "dimmed, dimmed, dimmed" that means nothing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coverage")
        .accessibilityValue("\(filled) of \(windowDays) days measured")
    }
}

/// The strip with its count spelled out beside it — the pairing used under the
/// Today screen's lead sentence.
struct CoverageSummary: View {
    let validDays: Int
    let windowDays: Int
    /// "days" for most metrics, "nights" for sleep. A night is not a day, and
    /// calling it one on the sleep screen reads as a rounding error.
    var noun: String = "days"

    var body: some View {
        HStack(spacing: 10) {
            CoverageStrip(validDays: validDays, windowDays: windowDays)
            Text("\(validDays) of \(windowDays) \(noun) measured")
                .font(.figure(12, weight: .regular))
                .foregroundStyle(Ink.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(validDays) of \(windowDays) \(noun) measured")
    }
}

/// The confidence grade as a pill, in the server's own vocabulary.
///
/// Four grades, and only one of them is reassuring — which is the point. An
/// "insufficient" badge on a figure is the app declining to let a number stand
/// on its own.
struct ConfidencePill: View {
    let confidence: String

    private var tint: Color {
        switch confidence {
        case "high": return Ink.measured
        case "moderate": return Ink.measured.opacity(0.8)
        case "low": return Ink.absent
        default: return Ink.faint
        }
    }

    private var label: String {
        switch confidence {
        case "high": return "High confidence"
        case "moderate": return "Moderate confidence"
        case "low": return "Low confidence"
        default: return "Not enough data"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
