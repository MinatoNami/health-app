import SwiftUI

/// One metric's share of the archive, as a bar.
///
/// Extracted so it can be rendered in isolation — a GeometryReader inside a
/// List row is easy to get subtly wrong, and "it compiled" is not evidence that
/// it looks right.
struct MetricBar: View {
    let slug: String
    let count: Int
    let maximum: Int
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(slug.metricDisplayName)
                    .font(.caption)
                    .lineLimit(1)
                if isStale {
                    Image(systemName: "moon.zzz")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Spacer()
                Text(Self.compact(count))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                Capsule()
                    .fill(isStale ? Color.orange.gradient : Color.accentColor.gradient)
                    .frame(width: max(3, geo.size.width * fraction))
            }
            // Height must be pinned: a GeometryReader left unconstrained in a
            // List row expands to fill the row and pushes everything apart.
            .frame(height: 5)
        }
        .padding(.vertical, 2)
        // Combined by hand rather than left to SwiftUI. Read as separate
        // elements this row is a name, a number, and a decorative capsule — and
        // the one thing it exists to flag, that a metric has stopped arriving,
        // was a bare `Image` with no label at all. Staleness is the whole point
        // of the orange bar, so it has to be spoken, not only coloured.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slug.metricDisplayName)
        .accessibilityValue(
            "\(count.formatted()) records"
                + (isStale ? ", nothing new in the last 48 hours" : "")
        )
    }

    private var fraction: Double {
        guard maximum > 0 else { return 0 }
        return min(1, Double(count) / Double(maximum))
    }

    /// Counts here are context, not the point — 258,932 reads no better than
    /// 259K and takes more room.
    static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
