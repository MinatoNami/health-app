import SwiftUI

/// Ask My Health, as a conversation.
///
/// A transcript with a composer pinned to the bottom, which is what every chat
/// interface looks like and therefore what nobody has to learn. The measured
/// week sits at the top as the opening message rather than as a separate block
/// of cards — same numbers, but they read as the thing the answers are built
/// from instead of an unrelated dashboard above a text box.
///
/// Explanations live in Settings → Insights. They were costing a paragraph of
/// reading on every visit to say something worth saying once.
struct InsightsView: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var services: AppServices

    @State private var question = ""
    @FocusState private var composerFocused: Bool

    private static let suggestions = [
        "How is my sleep?",
        "Am I more active?",
        "Enough data to see a trend?",
        "What should I focus on?",
    ]

    var body: some View {
        NavigationStack {
            Group {
                if !engine.isSignedIn {
                    ContentUnavailableView(
                        "Not signed in",
                        systemImage: "person.crop.circle.badge.xmark",
                        description: Text("Sign in on the Settings tab.")
                    )
                } else {
                    conversation
                }
            }
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .task { if engine.snapshot == nil { await engine.refreshSnapshot() } }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        // Opened from the 08:00 alert: lead with the thing the
                        // alert was about, then the numbers behind it.
                        if services.showBriefOnOpen, let brief = services.dailyBrief.lastBrief {
                            BriefBubble(brief: brief) { send("Why did that change?") }
                        }

                        if let snapshot = engine.snapshot {
                            SnapshotBubble(snapshot: snapshot)
                        }

                        if let question = engine.lastQuestion {
                            UserBubble(text: question)
                        }

                        if engine.isAsking {
                            PendingBubble()
                        } else if let result = engine.insight {
                            AnswerBubble(result: result)
                        }

                        if let error = engine.insightError ?? engine.snapshotError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(16)
                }
                .onChange(of: engine.insight) { _, _ in scroll(proxy) }
                .onChange(of: engine.isAsking) { _, _ in scroll(proxy) }
            }

            composer
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await engine.refreshSnapshot() }
    }

    private let bottomAnchor = "bottom"

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { send(suggestion) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button("Weekly review") {
                        composerFocused = false
                        Task { await engine.requestWeeklyReview() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
            }
            .disabled(engine.isAsking)

            HStack(spacing: 9) {
                TextField("Ask about your health data…", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 19))
                    .focused($composerFocused)

                Button {
                    send(question)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(engine.isAsking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(engine.isAsking || question.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 16)

            Text("Wellness guidance from your own data. Not medical advice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
        .padding(.top, 10)
        .background(.bar)
    }

    private func send(_ text: String) {
        let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        composerFocused = false
        question = ""
        Task { await engine.ask(asked) }
    }
}

// MARK: - Bubbles

/// What the morning alert said, expanded.
///
/// The alert is one line on a lock screen; this is the same finding with the
/// numbers under it and one tap to ask why. That is the "more details" the
/// notification is promising, and it has to be here the instant the app opens —
/// so it is the deterministic brief, not something generated on arrival.
private struct BriefBubble: View {
    let brief: DailyBrief
    var onAskWhy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Morning brief", systemImage: "sun.horizon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(brief.headline)
                .font(.headline)

            if !brief.detail.isEmpty {
                Text(brief.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(brief.movers) { mover in
                HStack(alignment: .firstTextBaseline) {
                    Text(mover.label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let value = mover.current.value {
                        Text(value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    if let pct = mover.changePct {
                        Text("\(pct > 0 ? "+" : "−")\(Int(abs(pct).rounded()))%")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
            }

            Button("Why did that change?", action: onAskWhy)
                .font(.caption)
                .padding(.top, 2)

            Text("Through \(brief.asOf)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The measured week, as the opening turn.
///
/// Deterministic, so it is there before any model runs — and still there when
/// the model is asleep on a laptop somewhere, which is the normal case.
private struct SnapshotBubble: View {
    let snapshot: HealthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This week vs your 28-day baseline")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(snapshot.metrics) { metric in
                MetricLine(metric: metric)
            }

            if let stale = snapshot.metricsNotSyncing, !stale.isEmpty {
                Divider()
                ForEach(stale) { item in
                    HStack {
                        Text(item.label).font(.caption)
                        Spacer()
                        Text("\(item.daysSince ?? 0)d ago")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("Not syncing. A gap is not a zero.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Label · value · delta on one line. The delta is the only tinted thing —
/// colouring the coverage bar and the confidence word too turned six metrics
/// into eighteen coloured elements.
private struct MetricLine: View {
    let metric: HealthSnapshot.Comparison

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.short[metric.metricSlug] ?? metric.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(format(metric.current.value))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(delta)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private var delta: String {
        guard metric.isUsable, let pct = metric.changePct else { return "—" }
        if abs(pct) < 0.5 { return "±0%" }
        return "\(pct > 0 ? "+" : "−")\(Int(abs(pct).rounded()))%"
    }

    private var tint: Color {
        switch metric.tone {
        case .good: return .green
        case .watch: return .red
        case .neutral: return .secondary
        }
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        let magnitude = abs(value)
        if magnitude >= 10_000 { return String(format: "%.1fK", value / 1000) }
        if magnitude >= 100 { return value.formatted(.number.precision(.fractionLength(0))) }
        return value.formatted(.number.precision(.fractionLength(magnitude < 10 ? 1 : 0)))
    }

    /// Standard abbreviations. A phone row is not wide enough for
    /// "Heart-rate variability" beside a value and a delta.
    static let short = [
        "resting_heart_rate": "Resting HR",
        "heart_rate_variability_sdnn": "HRV",
        "walking_heart_rate_average": "Walking HR",
        "apple_exercise_time": "Exercise",
        "sleep_analysis": "Sleep",
        "active_energy_burned": "Active energy",
        "distance_walking_running": "Distance",
    ]
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct PendingBubble: View {
    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
            Text("Reading your summaries…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The structured answer, inside one bubble.
///
/// Suggestions and limitations are behind a disclosure. They matter, but five
/// of them under every answer buries the answer itself.
private struct AnswerBubble: View {
    let result: InsightResult
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.safety.isElevated {
                Label(result.safety.headline,
                      systemImage: result.safety.level == "urgent"
                        ? "exclamationmark.triangle.fill" : "stethoscope")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(result.safety.level == "urgent" ? Color.red : Color.orange)
                ForEach(result.safety.reasons, id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let error = result.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }

            if let answer = result.answer {
                Text(answer.summary).font(.callout)

                ForEach(answer.observations) { observation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("• \(observation.statement)").font(.callout)
                        Text(observation.evidence)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                    }
                }

                let detailCount = answer.actions.count + answer.limitations.count
                if detailCount > 0 {
                    Button(showDetail ? "Less" : "Suggestions and limits (\(detailCount))") {
                        withAnimation { showDetail.toggle() }
                    }
                    .font(.caption)
                }

                if showDetail {
                    if !answer.actions.isEmpty {
                        Text("TRY").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        ForEach(answer.actions) { action in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("• \(action.action)").font(.callout)
                                Text("\(action.reason) · \(action.timeframe)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 12)
                            }
                        }
                    }
                    if !answer.limitations.isEmpty {
                        Text("LIMITS").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        ForEach(answer.limitations, id: \.self) { limitation in
                            Text("• \(limitation)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if answer.professionalReviewRecommended {
                    Text("Worth raising with a healthcare professional.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let model = result.model {
                Text("\(Int(Double(model.latencyMs) / 1000))s · \(model.name)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if result.isRuleBased {
                Text("Reviewed guidance — no model was consulted.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }
}
