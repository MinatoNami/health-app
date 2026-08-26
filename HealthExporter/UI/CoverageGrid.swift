import SwiftUI

/// Freshness of every tracked metric, as a grid of cells.
///
/// There are ~170 metrics. A list of "last seen" timestamps for all of them is
/// unreadable; colour across a grid shows the same thing in one glance — mostly
/// green is healthy, a spreading band of grey is the failure this app exists to
/// make visible. Never colour alone: the legend names each state, cells carry
/// an accessibility label, and tapping one names the metric.
struct CoverageGrid: View {
    /// One cell, fully resolved.
    ///
    /// Built once in `init` rather than derived in `body`, and that is the whole
    /// optimisation. Sorting ~170 metrics, formatting a relative date for each,
    /// and asking `Date()` for the time once per cell used to happen on every
    /// body evaluation — including every tap, since selecting a cell changes
    /// `@State`. Tapping one square re-sorted the entire grid.
    private struct Cell: Identifiable {
        var id: String { slug }
        let slug: String
        let name: String
        let color: Color
        let label: String
        /// Kept so the ordering stays exactly what it was — freshest first.
        /// Deriving it from `color` instead would have quietly re-sorted the grid
        /// while claiming to be a performance change.
        let lastSampleEnd: Date?
    }

    private let cells: [Cell]
    @State private var selectedSlug: String?

    private let columns = Array(repeating: GridItem(.flexible(minimum: 12), spacing: 4), count: 14)

    init(states: [String: AnchorStore.TypeState]) {
        // One `now` for the whole grid. Per-cell `Date()` also meant two cells
        // could in principle disagree about which side of a threshold they were.
        let now = Date()
        cells = states
            .map { identifier, state in
                let slug = identifier.healthKitSlug
                return Cell(
                    slug: slug,
                    name: slug.metricDisplayName,
                    color: Self.color(for: state, now: now),
                    label: Self.label(for: state),
                    lastSampleEnd: state.lastSampleEnd
                )
            }
            // Freshest first, so the healthy block is contiguous and any decay
            // shows as a growing tail rather than scattered noise.
            .sorted {
                ($0.lastSampleEnd ?? .distantPast) > ($1.lastSampleEnd ?? .distantPast)
            }
    }

    private var selected: Cell? {
        guard let selectedSlug else { return nil }
        return cells.first { $0.slug == selectedSlug }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(cells) { cell in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(cell.color)
                        .frame(height: 16)
                        .overlay {
                            if selectedSlug == cell.slug {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(Color.primary, lineWidth: 1.5)
                            }
                        }
                        .accessibilityLabel("\(cell.name), \(cell.label)")
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                selectedSlug = selectedSlug == cell.slug ? nil : cell.slug
                            }
                        }
                }
            }

            if let selected {
                HStack(spacing: 6) {
                    Circle().fill(selected.color).frame(width: 7, height: 7)
                    Text(selected.name)
                        .font(.caption.weight(.medium))
                    Text(selected.label)
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

    private static func color(for state: AnchorStore.TypeState, now: Date) -> Color {
        if state.lastError != nil { return .orange }
        guard let last = state.lastSampleEnd else { return .secondary.opacity(0.18) }
        let age = now.timeIntervalSince(last)
        if age < 24 * 3600 { return .green }
        if age < 72 * 3600 { return .yellow }
        return .secondary.opacity(0.28)
    }

    private static func label(for state: AnchorStore.TypeState) -> String {
        if let error = state.lastError { return error }
        guard let last = state.lastSampleEnd else { return "no data yet" }
        return last.formatted(.relative(presentation: .named))
    }
}
