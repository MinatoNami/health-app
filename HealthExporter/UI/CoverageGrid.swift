import SwiftUI

/// Freshness of every tracked metric, as a grid of cells.
///
/// There are ~170 metrics. A list of "last seen" timestamps for all of them is
/// unreadable; colour across a grid shows the same thing in one glance — mostly
/// green is healthy, a spreading band of grey is the failure this app exists to
/// make visible. Never colour alone: the legend names each state, cells carry
/// an accessibility label, and tapping one names the metric.
struct CoverageGrid: View {
    let states: [String: AnchorStore.TypeState]
    @State private var selected: (slug: String, state: AnchorStore.TypeState)?

    private let columns = Array(repeating: GridItem(.flexible(minimum: 12), spacing: 4), count: 14)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(entries, id: \.slug) { entry in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(for: entry.state))
                        .frame(height: 16)
                        .overlay {
                            if selected?.slug == entry.slug {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(Color.primary, lineWidth: 1.5)
                            }
                        }
                        .accessibilityLabel("\(entry.slug), \(label(for: entry.state))")
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                selected = selected?.slug == entry.slug ? nil : entry
                            }
                        }
                }
            }

            if let selected {
                HStack(spacing: 6) {
                    Circle().fill(color(for: selected.state)).frame(width: 7, height: 7)
                    Text(selected.slug.replacingOccurrences(of: "_", with: " "))
                        .font(.caption.weight(.medium))
                    Text(label(for: selected.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 14) {
                    legend(.green, "Fresh")
                    legend(.yellow, "Slowing")
                    legend(.secondary.opacity(0.28), "Quiet")
                    legend(.orange, "Error")
                }
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var entries: [(slug: String, state: AnchorStore.TypeState)] {
        states
            .map { (slug: $0.key.healthKitSlug, state: $0.value) }
            .sorted { lhs, rhs in
                // Freshest first, so the healthy block is contiguous and any
                // decay shows as a growing tail rather than scattered noise.
                (lhs.state.lastSampleEnd ?? .distantPast) > (rhs.state.lastSampleEnd ?? .distantPast)
            }
    }

    private func color(for state: AnchorStore.TypeState) -> Color {
        if state.lastError != nil { return .orange }
        guard let last = state.lastSampleEnd else { return .secondary.opacity(0.18) }
        let age = Date().timeIntervalSince(last)
        if age < 24 * 3600 { return .green }
        if age < 72 * 3600 { return .yellow }
        return .secondary.opacity(0.28)
    }

    private func label(for state: AnchorStore.TypeState) -> String {
        if let error = state.lastError { return error }
        guard let last = state.lastSampleEnd else { return "no data yet" }
        return last.formatted(.relative(presentation: .named))
    }
}
