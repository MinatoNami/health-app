import SwiftUI

/// Freshness across every tracked type.
///
/// Moved off the landing page. A 14-wide grid of coloured cells is a genuinely
/// good way to see ~170 metrics decaying at once, and it is also unmistakably a
/// developer tool — which is fine one tap in, and wrong as the third thing on a
/// screen that is supposed to look like Health.
struct CoverageDetailView: View {
    @State private var states: [String: AnchorStore.TypeState] = [:]

    var body: some View {
        List {
            if states.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing tracked yet",
                        systemImage: "square.grid.3x3",
                        description: Text("Run a sync to populate this.")
                    )
                }
            } else {
                Section {
                    CoverageGrid(states: states)
                        .padding(.vertical, 4)
                } footer: {
                    Text("One cell per metric, freshest first. A spreading band of grey is "
                         + "the failure this app exists to make visible — a permission that "
                         + "was revoked, or background delivery that quietly stopped.")
                }

                Section("Quiet longest") {
                    ForEach(quietest, id: \.slug) { entry in
                        LabeledContent {
                            Text(entry.state.lastSampleEnd.map {
                                $0.formatted(.relative(presentation: .named))
                            } ?? "never")
                            .foregroundStyle(.orange)
                        } label: {
                            Text(entry.slug.metricDisplayName)
                        }
                    }
                }
            }
        }
        .navigationTitle("Coverage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { states = AnchorStore.shared.all }
    }

    /// The tail of the grid, named. Colour shows *that* something has gone
    /// quiet; this says which, which is the part you can act on.
    private var quietest: [(slug: String, state: AnchorStore.TypeState)] {
        states
            .map { (slug: $0.key.healthKitSlug, state: $0.value) }
            .filter { entry in
                guard let last = entry.state.lastSampleEnd else { return false }
                return Date().timeIntervalSince(last) > 48 * 3600
            }
            .sorted { ($0.state.lastSampleEnd ?? .distantPast) < ($1.state.lastSampleEnd ?? .distantPast) }
            .prefix(12)
            .map { $0 }
    }
}
