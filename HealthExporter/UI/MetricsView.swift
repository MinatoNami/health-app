import SwiftUI
import HealthKit

/// Per-group permission control plus per-metric freshness.
struct MetricsView: View {
    @EnvironmentObject private var authorization: HealthAuthorization

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("iOS grants read access once per type. Enable a group "
                         + "before requesting access — afterwards, changes have to "
                         + "go through Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(MetricCatalog.groups) { group in
                    Section {
                        Toggle(isOn: Binding(
                            get: { authorization.enabledGroupIDs.contains(group.id) },
                            set: { authorization.setGroup(group.id, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title).font(.headline)
                                Text(group.blurb)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        NavigationLink {
                            GroupDetailView(group: group)
                        } label: {
                            Text("\(group.quantities.count + group.categories.count) types")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Metrics")
            .toolbar {
                Button("Enable All") { authorization.enableAll() }
            }
        }
    }
}

struct GroupDetailView: View {
    let group: MetricCatalog.Group

    var body: some View {
        List {
            ForEach(rows, id: \.identifier) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.slug.metricDisplayName).font(.body)
                    // The identifier still shown, quietly: this screen is also
                    // where you go to work out why a type is not arriving, and
                    // that conversation happens in slugs.
                    Text(row.slug).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        if let last = row.state?.lastSampleEnd {
                            Text("last \(last.formatted(date: .abbreviated, time: .shortened))")
                        } else {
                            Text("no data yet")
                        }
                        if let count = row.state?.totalRecords, count > 0 {
                            Text("· \(count) records")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let error = row.state?.lastError {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(group.title)
    }

    private struct Row {
        var identifier: String
        var slug: String
        var state: AnchorStore.TypeState?
    }

    private var rows: [Row] {
        let states = AnchorStore.shared.all
        var out: [Row] = []
        for name in group.quantities {
            let id = "HKQuantityTypeIdentifier" + name
            out.append(Row(identifier: id, slug: id.healthKitSlug, state: states[id]))
        }
        for name in group.categories {
            let id = "HKCategoryTypeIdentifier" + name
            out.append(Row(identifier: id, slug: id.healthKitSlug, state: states[id]))
        }
        if group.includesWorkouts {
            let id = HKObjectType.workoutType().identifier
            out.append(Row(identifier: id, slug: "workout", state: states[id]))
        }
        return out.sorted { $0.slug < $1.slug }
    }
}
