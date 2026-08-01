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
