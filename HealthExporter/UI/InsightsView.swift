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
    @State private var showingHistory = false
    @FocusState private var composerFocused: Bool

    private static let suggestions = [
        "How is my sleep?",
        "Am I more active?",
        "Enough data to see a trend?",
        "What should I focus on?",
    ]

    var body: some View {
        // The drawer wraps the NavigationStack rather than sitting inside it,
        // so it covers this screen's own navigation bar the way a chat list is
        // expected to. The tab bar below stays put — it belongs to the app, not
        // to this conversation.
        SideDrawer(isOpen: $showingHistory) {
            ChatHistoryView {
                withAnimation(.snappy(duration: 0.28)) { showingHistory = false }
            }
        } content: {
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
                .navigationTitle(engine.activeTitle ?? "Insights")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { if engine.isSignedIn { chatToolbar } }
                .task { if engine.snapshot == nil { await engine.refreshSnapshot() } }
            }
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                withAnimation(.snappy(duration: 0.28)) { showingHistory = true }
            } label: {
                Label("Chats", systemImage: "sidebar.leading")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    engine.newChat()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                if engine.activeSessionId != nil {
                    Button {
                        Task { await engine.compactActiveChat() }
                    } label: {
                        Label("Compact conversation", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    // Two exchanges is the least there is any point summarising;
                    // the server would refuse below that anyway.
                    .disabled(engine.pendingTurns < 2 || engine.isCompacting || engine.isAsking)
                }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        // Only at the head of a new conversation. These are
                        // *this week's* numbers, and printing them above a chat
                        // from three weeks ago captions it with figures it never
                        // mentioned.
                        if engine.transcript.isEmpty {
                            // Opened from the 08:00 alert: lead with the thing
                            // the alert was about, then the numbers behind it.
                            if services.showBriefOnOpen, let brief = services.dailyBrief.lastBrief {
                                BriefBubble(brief: brief) { send("Why did that change?") }
                            }

                            if let snapshot = engine.snapshot {
                                SnapshotBubble(snapshot: snapshot)
                            }
                        }

                        ForEach(Array(engine.transcript.enumerated()), id: \.element.id) { index, turn in
                            UserBubble(text: turn.question)

                            if turn.isPending {
                                PendingBubble()
                            } else {
                                AnswerBubble(turn: turn) { rating, note in
                                    guard let storedId = turn.storedId else { return }
                                    Task { await engine.rate(turnId: storedId, rating: rating, note: note) }
                                }
                            }

                            // The line where the model's memory of this chat
                            // becomes a summary. Everything above it is still
                            // here to read — that is the point of keeping the
                            // transcript out of compaction.
                            if engine.activeSummaryTurns > 0, index == engine.activeSummaryTurns - 1 {
                                CompactionSeam(
                                    turns: engine.activeSummaryTurns,
                                    summary: engine.activeSummary
                                )
                            }
                        }

                        if let notice = engine.chatNotice {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                .overlay {
                    if engine.isLoadingTranscript { ProgressView() }
                }
                .onChange(of: engine.transcript) { _, _ in scroll(proxy) }
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
                    if engine.transcript.isEmpty {
                        ForEach(Self.suggestions, id: \.self) { suggestion in
                            Button(suggestion) { send(suggestion) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
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

            // Computed once. It was evaluated twice per keystroke — once for
            // `disabled`, once for `opacity` — on a view that rebuilds on every
            // character typed.
            let canSend = !engine.isAsking
                && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

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
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
            }
            .padding(.horizontal, 16)

            Text("Wellness guidance from your own data. Not medical advice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
        .padding(.top, 10)
        // An opaque background with a hairline, rather than the `.bar` material.
        // A material is a live blur of whatever is behind it, recomposited as
        // that content moves — and the moment it moves most is the keyboard
        // animating in underneath this exact view. Visually near-identical here,
        // because the composer sits against a plain grouped background anyway.
        .background(alignment: .top) {
            Color(.secondarySystemGroupedBackground)
                .overlay(alignment: .top) { Divider() }
                .ignoresSafeArea()
        }
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
    let turn: ChatTurn
    /// (rating, note) — either may be nil to leave that half alone.
    let onFeedback: (Int?, String?) -> Void

    @State private var showDetail = false
    @State private var editingNote = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let safety = turn.safety, safety.isElevated {
                Label(safety.headline,
                      systemImage: safety.level == "urgent"
                        ? "exclamationmark.triangle.fill" : "stethoscope")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(safety.level == "urgent" ? Color.red : Color.orange)
                ForEach(safety.reasons, id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let error = turn.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }

            if let answer = turn.answer {
                Text(answer.summary).font(.callout)

                ForEach(answer.observations) { observation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\u{2022} \(observation.statement)").font(.callout)
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
                                Text("\u{2022} \(action.action)").font(.callout)
                                Text("\(action.reason) \u{b7} \(action.timeframe)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 12)
                            }
                        }
                    }
                    if !answer.limitations.isEmpty {
                        Text("LIMITS").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        ForEach(answer.limitations, id: \.self) { limitation in
                            Text("\u{2022} \(limitation)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if answer.professionalReviewRecommended {
                    Text("Worth raising with a healthcare professional.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            footer

            if !turn.note.isEmpty && !editingNote {
                Text(turn.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle().frame(width: 2).foregroundStyle(Color.accentColor)
                    }
            }

            if editingNote {
                TextField("What was wrong or right about this answer?", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { editingNote = false }.font(.caption)
                    Button("Save") {
                        onFeedback(turn.rating, draft)
                        editingNote = false
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    /// What produced the answer, and what you made of it.
    ///
    /// The rating sits with the answer rather than in a survey afterwards: the
    /// judgement is worth most while the answer is still on screen and you can
    /// still see what it got wrong.
    private var footer: some View {
        HStack(spacing: 10) {
            Group {
                if let name = turn.modelName, let ms = turn.latencyMs {
                    Text("\(Int(Double(ms) / 1000))s \u{b7} \(name)")
                } else if turn.isRuleBased {
                    Text("Reviewed guidance \u{2014} no model was consulted.")
                } else if turn.answer != nil {
                    Text("No model ran.")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            Spacer()

            // Only a stored turn can be rated — a rating needs a row to live
            // on. A question asked with "don't remember this" has none, which
            // is correct: there is nothing to attach an opinion to.
            if turn.storedId != nil {
                thumb(1, filled: "hand.thumbsup.fill", hollow: "hand.thumbsup")
                thumb(-1, filled: "hand.thumbsdown.fill", hollow: "hand.thumbsdown")
                Button {
                    draft = turn.note
                    editingNote = true
                } label: {
                    Image(systemName: turn.note.isEmpty ? "text.bubble" : "text.bubble.fill")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func thumb(_ value: Int, filled: String, hollow: String) -> some View {
        Button {
            // A second press on the same thumb clears it. People mis-tap, and a
            // rating you cannot take back is one nobody trusts enough to give.
            onFeedback(turn.rating == value ? nil : value, nil)
        } label: {
            Image(systemName: turn.rating == value ? filled : hollow)
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(turn.rating == value ? Color.accentColor : .secondary)
        .accessibilityLabel(value > 0 ? "Useful" : "Not useful")
    }
}

/// Where the model's memory of this conversation becomes a paragraph.
///
/// Drawn as a seam rather than a banner: the messages above it are still there
/// to read, so this should say "folded", not "deleted".
private struct CompactionSeam: View {
    let turns: Int
    let summary: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Text("\(turns) earlier message\(turns == 1 ? "" : "s") compacted")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            }

            if expanded, let summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
