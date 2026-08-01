import SwiftUI

/// How the numbers on the Insights tab are arrived at.
///
/// Lives here rather than on the Insights screen because it is read once and
/// then never again — as inline footnotes it cost a paragraph of reading on
/// every visit to explain something that had not changed since the last one.
struct InsightsAboutView: View {
    var body: some View {
        List {
            Section {
                explain("Windows",
                        "The last 7 days against the 28 before them. They do not overlap: "
                        + "a week compared against a baseline containing it hides the change.")
                explain("Today",
                        "Left out. Half a day of steps against full-day baselines reads as a "
                        + "collapse in activity that is only the clock.")
                explain("Coverage",
                        "Scored against how often a metric is expected, not against every "
                        + "calendar day. Three weighings a week is full coverage for weight.")
                explain("Estimated",
                        "iPhone and Watch both write step counts, so a day without Apple's "
                        + "deduplicated total is summed from raw samples and can read high. "
                        + "Totals only — averaging the same readings twice gives the same average.")
                explain("Consistency",
                        "The spread of your sleep midpoint: when you sleep, not how long.")
            } header: {
                Text("How the numbers work")
            }

            Section {
                explain("Escalation",
                        "Decided by rules before the model runs. Anything urgent is answered "
                        + "from reviewed text, with no model involved at all.")
                explain("Symptoms",
                        "A described symptom outranks every measurement. Wearable data cannot "
                        + "establish a cause, and normal-looking readings are never a reason "
                        + "to wait.")
                explain("Limits",
                        "No diagnosis, no medication advice, and no claim that this data can "
                        + "rule out illness.")
            } header: {
                Text("Safety")
            } footer: {
                Text("Wellness guidance from your own data. Not medical advice.")
            }

            Section {
                explain("Where",
                        "Summaries are explained by a model on your own machine, over your "
                        + "private tailnet. Nothing is sent to a third party.")
                explain("What",
                        "The model receives prepared summaries — averages, windows, coverage "
                        + "— never your individual records.")
                explain("Retention",
                        "Questions and answers are deleted automatically. The health figures "
                        + "behind an answer are never stored with it.")
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("How insights work")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func explain(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
