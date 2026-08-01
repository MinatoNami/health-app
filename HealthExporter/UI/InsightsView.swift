import SwiftUI

/// Ask My Health.
///
/// The measured comparison comes first and the generated explanation second,
/// which is also the order they become available: the snapshot is a single fast
/// query, an answer is a local model working for half a minute. Arranged this
/// way the screen is useful immediately and gets better, rather than being a
/// spinner over a text box.
///
/// Nothing here recomputes anything. Every number is the server's, so the phone
/// and the dashboard cannot tell different stories about the same week.
struct InsightsView: View {
    @EnvironmentObject private var engine: SyncEngine

    @State private var question = ""
    @State private var context = ""
    @State private var remember = true
    @FocusState private var questionFocused: Bool

    /// The questions §10 phase 3 lists. Present because an empty box invites
    /// "how am I doing", which is the one question with no useful answer.
    private static let suggestions = [
        "How has my sleep changed this month?",
        "Am I becoming more or less active?",
        "Is there enough data to identify a trend?",
        "Which area should I focus on first?",
    ]

    var body: some View {
        NavigationStack {
            List {
                if !engine.isSignedIn {
                    Section {
                        ContentUnavailableView(
                            "Not signed in",
                            systemImage: "person.crop.circle.badge.xmark",
                            description: Text("Sign in on the Settings tab to see your health summary.")
                        )
                    }
                } else {
                    if let snapshot = engine.snapshot {
                        baselineSection(snapshot)
                        if let stale = snapshot.metricsNotSyncing, !stale.isEmpty {
                            staleSection(stale)
                        }
                        if let sleep = snapshot.sleep, sleep.nightsRecorded > 0 {
                            sleepSection(sleep)
                        }
                    } else if engine.snapshotError == nil {
                        Section { ProgressView("Reading your summary…") }
                    }

                    askSection

                    if let result = engine.insight {
                        answerSections(result)
                    }

                    if let error = engine.insightError {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    privacySection
                }

                if let error = engine.snapshotError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Insights")
            .refreshable { await engine.refreshSnapshot() }
            .task {
                if engine.snapshot == nil { await engine.refreshSnapshot() }
            }
        }
    }

    // MARK: - Measured

    private func baselineSection(_ snapshot: HealthSnapshot) -> some View {
        Section {
            ForEach(snapshot.metrics) { metric in
                BaselineRow(metric: metric)
            }
            if snapshot.metrics.isEmpty {
                Text("No analysable metrics have arrived yet. Run a sync, and comparisons appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Last 7 days vs your 28-day baseline")
        } footer: {
            Text("Through \(snapshot.asOf). Today is left out because it is only half over — "
                 + "a partial day against full-day baselines reads as a collapse that is really just the clock.")
        }
    }

    /// Metrics that were arriving and stopped.
    ///
    /// This is the silent failure the whole app is built around: a revoked
    /// permission, a watch left in a drawer, or background delivery dying after
    /// an OS update all look exactly like a quiet week.
    private func staleSection(_ stale: [HealthSnapshot.Stale]) -> some View {
        Section {
            ForEach(stale) { item in
                LabeledContent {
                    Text(item.daysSince.map { "\($0)d ago" } ?? "never")
                        .foregroundStyle(.orange)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label)
                        if let last = item.lastRecordedAt {
                            Text("last recorded \(last.prefix(10))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Not syncing")
        } footer: {
            Text("A gap is not a zero — a watch that was not worn is not a night without "
                 + "sleep. Check Health permissions for these types on the Metrics tab.")
        }
    }

    private func sleepSection(_ sleep: HealthSnapshot.Sleep) -> some View {
        Section("Sleep pattern") {
            if let hours = sleep.averageHours {
                LabeledContent("Average", value: String(format: "%.1f h", hours))
            }
            if let bedtime = sleep.typicalBedtime {
                LabeledContent("Typical bedtime", value: bedtime)
            }
            if let wake = sleep.typicalWakeTime {
                LabeledContent("Typical wake", value: wake)
            }
            LabeledContent("Schedule", value: sleep.consistency)
            Text("\(sleep.nightsRecorded) of \(sleep.windowDays) nights recorded. Consistency is the "
                 + "spread of the sleep midpoint — when you sleep, not how long.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Ask

    private var askSection: some View {
        Section {
            TextField("What might be contributing to my tiredness?", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .focused($questionFocused)
                .disabled(engine.isAsking)

            TextField("Optional context — travel, illness, a new routine…", text: $context)
                .font(.callout)
                .disabled(engine.isAsking)

            Toggle("Keep this question", isOn: $remember)
                .font(.callout)

            Button {
                questionFocused = false
                let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await engine.ask(asked, context: context, remember: remember) }
            } label: {
                if engine.isAsking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Thinking…")
                    }
                } else {
                    Label("Ask", systemImage: "sparkles")
                }
            }
            .disabled(engine.isAsking || question.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("Weekly review") {
                questionFocused = false
                Task { await engine.requestWeeklyReview() }
            }
            .disabled(engine.isAsking)

            // Horizontal, not a vertical stack of buttons: four full-width rows
            // of suggestion would push the answer off the screen entirely.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            question = suggestion
                            questionFocused = false
                            Task { await engine.ask(suggestion, context: context, remember: remember) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(engine.isAsking)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
        } header: {
            Text("Ask about your data")
        } footer: {
            Text("Answers are built from the measured summaries above. This is wellness guidance, "
                 + "not medical advice, and it cannot diagnose anything."
                 + (engine.isAsking ? " A local model takes about half a minute." : ""))
        }
    }

    // MARK: - Answer

    @ViewBuilder
    private func answerSections(_ result: InsightResult) -> some View {
        // Decided by rules before the model ran, so it shows whether or not
        // anything was generated.
        if result.safety.isElevated {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(result.safety.headline,
                          systemImage: result.safety.level == "urgent"
                            ? "exclamationmark.triangle.fill" : "stethoscope")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(result.safety.level == "urgent" ? .red : .orange)
                    ForEach(result.safety.reasons, id: \.self) { reason in
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }

        if let error = result.error {
            Section {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }

        if let answer = result.answer {
            Section("Summary") {
                Text(answer.summary).font(.callout)
                if !answer.periodExamined.isEmpty {
                    Text(answer.periodExamined).font(.caption2).foregroundStyle(.secondary)
                }
            }

            if !answer.observations.isEmpty {
                Section("What the data shows") {
                    ForEach(answer.observations) { observation in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(observation.statement).font(.callout)
                            Text(observation.evidence).font(.caption).foregroundStyle(.secondary)
                            Text("\(observation.confidence) confidence")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !answer.actions.isEmpty {
                Section("Worth trying") {
                    ForEach(answer.actions) { action in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(action.action, systemImage: "arrow.right.circle")
                                .font(.callout)
                            Text(action.reason).font(.caption).foregroundStyle(.secondary)
                            Text(action.timeframe).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !answer.limitations.isEmpty {
                Section("What this cannot tell you") {
                    ForEach(answer.limitations, id: \.self) { limitation in
                        Text(limitation).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if answer.professionalReviewRecommended {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("A healthcare professional is the right person to ask",
                              systemImage: "cross.case")
                            .font(.subheadline.weight(.semibold))
                        if let reason = answer.professionalReviewReason, !reason.isEmpty {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        Section {
            if let model = result.model {
                Text("\(model.name) · \(String(format: "%.1f", Double(model.latencyMs) / 1000))s · "
                     + "processed \(model.destination?.description ?? "locally")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if result.isRuleBased {
                Text("Answered from reviewed guidance. No model was consulted.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Clear answer") { engine.clearInsight() }
                .font(.caption)
        }
    }

    // MARK: - Privacy

    @ViewBuilder
    private var privacySection: some View {
        if let status = engine.insightStatus {
            Section {
                Label(
                    status.isReady
                        ? "Processed \(status.destination?.description ?? "on your server")"
                        : "Insight generation is unavailable",
                    systemImage: status.isReady ? "lock.shield" : "bolt.slash"
                )
                .font(.caption)
                .foregroundStyle(status.isReady ? Color.secondary : Color.orange)

                if status.isReady {
                    Text("\(status.model ?? "local model") · questions are deleted after "
                         + "\(status.retentionDays ?? 30) days · nothing is sent to a third party.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let detail = status.detail {
                    Text("\(detail) The measured summary above does not need it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One metric against its own baseline: the value, the change, and how much of
/// the window was actually recorded.
///
/// The coverage bar is the point. A seven-day average built from two days the
/// watch was worn is not a weekly average, and a row that showed only the number
/// would present both as the same claim.
private struct BaselineRow: View {
    let metric: HealthSnapshot.Comparison

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(format(metric.current.value))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                + Text(" \(metric.unit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if metric.isUsable, let change = metric.change {
                HStack(spacing: 6) {
                    Text(delta(change, pct: metric.changePct))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text("vs \(format(metric.baseline.value)) baseline")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Not enough data to compare")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Width is coverage and colour is coverage — one variable, so a full
            // bar can never be painted as though something were missing.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(coverageTint)
                        .frame(width: max(2, geometry.size.width * coverage))
                }
            }
            .frame(height: 4)

            Text("\(metric.confidence.capitalized) · \(metric.current.validDays)/"
                 + "\(metric.current.windowDays) days · \(metric.confidenceReason)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var coverage: Double {
        metric.current.coverage
            ?? (metric.current.windowDays > 0
                ? Double(metric.current.validDays) / Double(metric.current.windowDays)
                : 0)
    }

    private var coverageTint: Color {
        if coverage >= 0.85 { return .green }
        if coverage >= 0.5 { return .orange }
        return .red
    }

    private var tint: Color {
        switch metric.tone {
        case .good: return .green
        case .watch: return .red
        case .neutral: return .secondary
        }
    }

    private func delta(_ change: Double, pct: Double?) -> String {
        let sign = change > 0 ? "+" : change < 0 ? "−" : ""
        let magnitude = format(abs(change))
        guard let pct else { return "\(sign)\(magnitude)" }
        return "\(sign)\(magnitude) (\(sign)\(String(format: "%.1f", abs(pct)))%)"
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        let magnitude = abs(value)
        if magnitude >= 10_000 { return String(format: "%.1fK", value / 1000) }
        if magnitude >= 100 { return value.formatted(.number.precision(.fractionLength(0))) }
        return value.formatted(.number.precision(.fractionLength(magnitude < 10 ? 2 : 1)))
    }
}
