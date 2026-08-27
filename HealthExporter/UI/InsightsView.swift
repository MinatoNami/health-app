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
    /// Whether the transcript is pinned to the newest message. False the moment
    /// somebody scrolls back through the conversation, and nothing that arrives
    /// afterwards is allowed to drag them out of it.
    @State private var isFollowing = true
    @FocusState private var composerFocused: Bool

    private static let suggestions = [
        "How is my sleep?",
        "Am I more active?",
        "Enough data to see a trend?",
        "What should I focus on?",
    ]

    var body: some View {
        // The chat history drawer is drawn by `RootView`, above the tab bar.
        // This screen only opens it.
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

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                withAnimation(.snappy(duration: 0.28)) { services.showingChatHistory = true }
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
                                PendingBubble(label: engine.askingLabel)
                            } else {
                                AnswerBubble(
                                    turn: turn,
                                    onFeedback: { rating, note in
                                        guard let storedId = turn.storedId else { return }
                                        Task {
                                            await engine.rate(
                                                turnId: storedId, rating: rating, note: note
                                            )
                                        }
                                    },
                                    onAgain: { send($0) }
                                )
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
                                .font(.system(size: 12.5))
                                .foregroundStyle(Ink.faint)
                        }

                        if let error = engine.insightError ?? engine.snapshotError {
                            Text(error)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Ink.absent)
                        }

                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .overlay {
                    if engine.isLoadingTranscript { ProgressView().tint(Ink.muted) }
                }
                // The way back. Nothing drags the view to the newest message any
                // more, which is right while reading and useless once you want
                // to return.
                .overlay(alignment: .bottom) {
                    if !isFollowing, !engine.transcript.isEmpty {
                        Button {
                            isFollowing = true
                            proxy.scrollTo(bottomAnchor, anchor: .bottom)
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Ink.secondary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 7)
                                .background(Ink.raised, in: Capsule())
                                .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isFollowing)
                // A bubble being added should move the conversation up under
                // it, which is what anchoring the bottom means: the content
                // grows and the newest row is already in place. Scrolling to it
                // instead — which is what this did — shows the viewport
                // travelling to find the message, and that is the part that
                // reads as wrong.
                //
                // Anchoring also opens a conversation at its newest message
                // without sliding through everything above it.
                .defaultScrollAnchor(.bottom)
                // Whether the reader is following or has gone back through the
                // chat. The anchor handles the bottom; this is only so the two
                // deliberate jumps below know whether to interrupt.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - Self.nearBottom
                } action: { _, nearBottom in
                    isFollowing = nearBottom
                }
                // Sending is a statement that you want to see the reply, so it
                // returns to the bottom from wherever you had scrolled to.
                // Nothing else moves the view: a rating changes the turn it is
                // recorded against and must not move anything, which is why
                // this is not `of: engine.transcript`.
                .onChange(of: engine.isAsking) { _, asking in
                    if asking {
                        isFollowing = true
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                // A different conversation opens at its newest message.
                .onChange(of: engine.activeSessionId) { _, _ in
                    isFollowing = true
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }

            composer
        }
        .background(Ink.ground)
        .refreshable { await engine.refreshSnapshot() }
    }

    private let bottomAnchor = "bottom"

    /// How far from the bottom still counts as following the conversation.
    private static let nearBottom: CGFloat = 120

    private var composer: some View {
        Composer(
            question: $question,
            focused: $composerFocused,
            showsSuggestions: engine.transcript.isEmpty,
            suggestions: Self.suggestions,
            isAsking: engine.isAsking,
            onSend: { send($0) },
            onWeeklyReview: {
                composerFocused = false
                Task { await engine.requestWeeklyReview() }
            }
        )
    }

    private func send(_ text: String) {
        let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        composerFocused = false
        question = ""
        Task { await engine.ask(asked) }
    }
}

/// The ask bar and the chips above it.
///
/// Its own view because it is the most-changed control on this screen and the
/// one that cannot be seen without a signed-in app and a running model. Taking
/// plain values rather than the environment is what lets `InsightsRenderTests`
/// draw it in both states — empty and armed — which is the whole difference
/// between "it compiles" and "it looks right".
private struct Composer: View {
    @Binding var question: String
    @FocusState.Binding var focused: Bool
    let showsSuggestions: Bool
    let suggestions: [String]
    let isAsking: Bool
    let onSend: (String) -> Void
    let onWeeklyReview: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if showsSuggestions {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { onSend(suggestion) }
                                .buttonStyle(ChipStyle())
                        }
                    }
                    Button("Weekly review", action: onWeeklyReview)
                        .buttonStyle(ChipStyle())
                }
                .padding(.horizontal, 20)
            }
            .disabled(isAsking)

            // Computed once. It was evaluated twice per keystroke — once for
            // `disabled`, once for `opacity` — on a view that rebuilds on every
            // character typed.
            let canSend = !isAsking
                && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // One field, with the button inside it. The board draws a single
            // 24pt pill rather than a field and a detached circle: at this
            // corner radius two shapes side by side read as a control that did
            // not finish laying out.
            HStack(spacing: 10) {
                TextField("", text: $question, axis: .vertical)
                    .prompt(showsSuggestions ? "Ask about your health data" : "Ask a follow-up",
                            visible: question.isEmpty)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.primary)
                    .tint(Ink.accent)
                    .focused($focused)

                // Accent once there is something to send, inert grey before —
                // straight from the two boards, and the only moving part in the
                // composer. It is how the control says it is armed without a
                // label saying so.
                Button {
                    onSend(question)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canSend ? Ink.ground : Ink.faint)
                        .frame(width: 32, height: 32)
                        .background(canSend ? Ink.accent : Ink.hairline, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.15), value: canSend)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 15)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .background(Ink.field, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Ink.hairline, lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        // An opaque background with a hairline, rather than the `.bar` material.
        // A material is a live blur of whatever is behind it, recomposited as
        // that content moves — and the moment it moves most is the keyboard
        // animating in underneath this exact view.
        .background(alignment: .top) {
            Ink.ground
                .overlay(alignment: .top) { Rectangle().fill(Ink.divider).frame(height: 1) }
                .ignoresSafeArea()
        }
    }
}

/// A suggestion chip: 40pt tall, hairline, quiet until tapped.
private struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Ink.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
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
            Text("Morning brief").sectionLabelStyle()

            Text(brief.headline)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !brief.detail.isEmpty {
                Text(brief.detail)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Ink.secondary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(brief.movers) { mover in
                HStack(alignment: .firstTextBaseline) {
                    Text(mover.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.secondary)
                    Spacer(minLength: 6)
                    if let value = mover.current.value {
                        Text(value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))))
                            .font(.figure(13))
                            .foregroundStyle(Ink.primary)
                    }
                    if let pct = mover.changePct {
                        Text("\(pct > 0 ? "+" : "−")\(Int(abs(pct).rounded()))%")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Ink.muted)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            Button("Why did that change?", action: onAskWhy)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.accent)
                .buttonStyle(.plain)
                .padding(.top, 2)

            Text("Through \(brief.asOf)")
                .font(.figure(11, weight: .regular))
                .foregroundStyle(Ink.faint)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// The measured week, as the opening turn.
///
/// Deterministic, so it is there before any model runs — and still there when
/// the model is asleep on a laptop somewhere, which is the normal case.
private struct SnapshotBubble: View {
    let snapshot: HealthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                HStack {
                    Text("Your measured week").sectionLabelStyle()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 12)

                ForEach(snapshot.metrics) { metric in
                    Rectangle().fill(Ink.divider).frame(height: 1)
                    MetricLine(metric: metric)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                }

                if let stale = snapshot.metricsNotSyncing, !stale.isEmpty {
                    Rectangle().fill(Ink.divider).frame(height: 1)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(stale) { item in
                            HStack {
                                Text(item.label)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Ink.secondary)
                                Spacer(minLength: 6)
                                Text("\(item.daysSince ?? 0)d ago")
                                    .font(.figure(12))
                                    .foregroundStyle(Ink.absent)
                            }
                        }
                        // The rule the whole app is built around, said where a
                        // reader is most likely to mistake absence for a zero.
                        Text("Not syncing. A gap is not a zero.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Ink.faint)
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            // Outside the card, in the board, and it belongs there: it is an
            // instruction about the screen rather than a row of the table.
            Text("Ask anything about these figures. Answers cite the days they were measured from.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.faint)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Label · value · delta on one line. The delta is the only tinted thing —
/// colouring the coverage bar and the confidence word too turned six metrics
/// into eighteen coloured elements.
private struct MetricLine: View {
    let metric: HealthSnapshot.Comparison

    var body: some View {
        HStack(spacing: 12) {
            Text(MetricStyle.shortLabel(metric.metricSlug, fallback: metric.label))
                .font(.system(size: 13))
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: 6)
            // Both shared with Today rather than reimplemented here, which is
            // what this was: a private abbreviation table and a private number
            // formatter, one screen apart from the ones Today uses. Two
            // renderings of the same figure that can drift is precisely the
            // thing the server-side-analysis rule exists to avoid.
            Text(MetricFormat.value(metric.current.value, slug: metric.metricSlug))
                .font(.figure(13))
                .foregroundStyle(Ink.primary)
            Text(MetricStyle.unit(metric.unit, slug: metric.metricSlug))
                .font(.system(size: 11))
                .foregroundStyle(Ink.faint)
            Text(delta)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var delta: String {
        guard metric.isUsable, let pct = metric.changePct else { return "—" }
        if abs(pct) < 0.5 { return "±0%" }
        return "\(pct > 0 ? "+" : "−")\(Int(abs(pct).rounded()))%"
    }

    private var tint: Color {
        switch metric.tone {
        case .good: return Ink.measured
        case .watch: return Ink.absent
        case .neutral: return Ink.muted
        }
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Ink.primary)
                .lineSpacing(2)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(
                    Ink.quoted,
                    // Square on the corner nearest the sender. It is the one
                    // cue that says which side said this without a label, and
                    // it is why the answers below need no bubble at all.
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 17, bottomLeadingRadius: 17,
                        bottomTrailingRadius: 5, topTrailingRadius: 17,
                        style: .continuous
                    )
                )
        }
    }
}

private struct PendingBubble: View {
    /// What the server is doing right now, or empty before the first step is
    /// reported. An answer takes fifteen to ninety seconds and this line is all
    /// there is to look at for the length of it.
    var label: String = ""

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Ink.muted)
            Text("\(label.isEmpty ? "Reading your summaries" : label)…")
                .font(.system(size: 14))
                .foregroundStyle(Ink.muted)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: label)
        }
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
    /// Ask this turn's question again, as a new turn.
    let onAgain: (String) -> Void

    @State private var showDetail = false
    @State private var editingNote = false
    @State private var draft = ""
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let safety = turn.safety, safety.isElevated {
                Label(safety.headline,
                      systemImage: safety.level == "urgent"
                        ? "exclamationmark.triangle.fill" : "stethoscope")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(safety.level == "urgent" ? Ink.accent : Ink.absent)
                ForEach(safety.reasons, id: \.self) { reason in
                    Text(reason).font(.system(size: 12.5)).foregroundStyle(Ink.muted)
                }
            }

            if let error = turn.error {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Ink.muted)
            }

            if let answer = turn.answer {
                // No bubble. The board gives the question a bubble and leaves
                // the answer plain on the ground: on a screen where answers are
                // long and questions are one line, boxing both makes the answer
                // look like a quotation of itself.
                Text(answer.summary)
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.primary)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(answer.observations) { observation in
                    Text(observation.statement)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.primary)
                        .lineSpacing(3.5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                evidence(for: answer)

                let detailCount = answer.actions.count + answer.limitations.count
                if detailCount > 0 {
                    Button(showDetail ? "Less" : "Suggestions and limits (\(detailCount))") {
                        withAnimation { showDetail.toggle() }
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Ink.muted)
                    .buttonStyle(.plain)
                }

                if showDetail {
                    if !answer.actions.isEmpty {
                        Text("Try").sectionLabelStyle().padding(.top, 2)
                        ForEach(answer.actions) { action in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\u{2022} \(action.action)")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Ink.primary)
                                Text("\(action.reason) \u{b7} \(action.timeframe)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Ink.faint)
                                    .padding(.leading, 12)
                            }
                        }
                    }
                    if !answer.limitations.isEmpty {
                        Text("Limits").sectionLabelStyle().padding(.top, 2)
                        ForEach(answer.limitations, id: \.self) { limitation in
                            Text("\u{2022} \(limitation)")
                                .font(.system(size: 13))
                                .foregroundStyle(Ink.secondary)
                        }
                    }
                }

                if answer.professionalReviewRecommended {
                    Text("Worth raising with a healthcare professional.")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.absent)
                }
            }

            footer

            if !turn.note.isEmpty && !editingNote {
                Text(turn.note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ink.muted)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) {
                        Rectangle().frame(width: 2).foregroundStyle(Ink.accent)
                    }
            }

            if editingNote {
                TextField("What was wrong or right about this answer?", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Ink.primary)
                    .tint(Ink.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Ink.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Ink.hairline, lineWidth: 1)
                    )
                HStack(spacing: 14) {
                    Spacer()
                    Button("Cancel") { editingNote = false }
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.muted)
                        .buttonStyle(.plain)
                    Button("Save") {
                        onFeedback(turn.rating, draft)
                        editingNote = false
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The days the answer rests on, and the disclaimer that belongs with it.
    ///
    /// The board draws this as a table of metrics with a coverage strip on each
    /// row. That cannot be built from what an answer returns: `Observation`
    /// carries `statement`, a prose `evidence` string and `confidence` — no
    /// metric slug, no figure, and no valid/window days. Inventing strips here
    /// would be drawing coverage nobody measured, which is the exact failure
    /// the strip exists to expose. So the card holds the period and the real
    /// evidence lines, and the strips wait for the server to send the numbers.
    @ViewBuilder
    private func evidence(for answer: HealthInsight) -> some View {
        let lines = answer.observations.filter { !$0.evidence.isEmpty }
        VStack(spacing: 0) {
            HStack {
                Text("Measured from").sectionLabelStyle()
                Spacer(minLength: 8)
                if !answer.periodExamined.isEmpty {
                    Text(answer.periodExamined)
                        .font(.figure(10, weight: .regular))
                        .foregroundStyle(Ink.faint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ForEach(lines) { observation in
                Rectangle().fill(Ink.divider).frame(height: 1)
                HStack(alignment: .top, spacing: 10) {
                    Text(observation.evidence)
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if !observation.confidence.isEmpty {
                        Text(observation.confidence)
                            .font(.figure(10, weight: .regular))
                            .textCase(.uppercase)
                            .foregroundStyle(Ink.faint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }

            Rectangle().fill(Ink.divider).frame(height: 1)
            // Attached to the answer rather than parked under the composer,
            // where it was shown on every screen including the empty one. It
            // qualifies advice, so it belongs where advice appears.
            Text("Wellness guidance from your own data. Not medical advice.")
                .font(.system(size: 11))
                .foregroundStyle(Ink.faint)
                .lineSpacing(1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Ink.ground.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// What produced the answer, and what you made of it.
    ///
    /// The rating sits with the answer rather than in a survey afterwards: the
    /// judgement is worth most while the answer is still on screen and you can
    /// still see what it got wrong.
    private var footer: some View {
        HStack(spacing: 10) {
            Group {
                // Just the time: the date belongs to the conversation, and a
                // full timestamp under every bubble is noise on a chat that
                // happened in one sitting.
                let at = turn.createdAt.formatted(date: .omitted, time: .shortened)
                if let name = turn.modelName, let ms = turn.latencyMs {
                    Text("\(at) \u{b7} \(Int(Double(ms) / 1000))s \u{b7} \(name)")
                } else if turn.isRuleBased {
                    Text("\(at) \u{b7} Reviewed guidance \u{2014} no model was consulted.")
                } else if turn.answer != nil {
                    Text("\(at) \u{b7} No model ran.")
                }
            }
            .font(.figure(10.5, weight: .regular))
            .foregroundStyle(Ink.faint)

            Spacer(minLength: 8)

            if turn.answer != nil {
                Button {
                    UIPasteboard.general.string = turn.plainText
                    withAnimation { didCopy = true }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(didCopy ? Ink.accent : Ink.faint)
                .task(id: didCopy) {
                    guard didCopy else { return }
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation { didCopy = false }
                }

                // Appends rather than replacing: a stored answer is the record
                // of what was said, and being able to reproduce a generated
                // health claim later is the whole reason to keep one. Two
                // answers to one question is also the comparison worth having
                // while a prompt is being tuned.
                if !turn.question.isEmpty {
                    Button { onAgain(turn.question) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.system(size: 13))
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.faint)
                }
            }

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
                .font(.system(size: 13))
                .buttonStyle(.plain)
                .foregroundStyle(turn.note.isEmpty ? Ink.faint : Ink.accent)
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
        .font(.system(size: 13))
        .buttonStyle(.plain)
        .foregroundStyle(turn.rating == value ? Ink.accent : Ink.faint)
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
                Rectangle().fill(Ink.divider).frame(height: 1)
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Text("\(turns) earlier message\(turns == 1 ? "" : "s") compacted")
                        .font(.figure(10.5, weight: .regular))
                        .foregroundStyle(Ink.faint)
                }
                .buttonStyle(.plain)
                Rectangle().fill(Ink.divider).frame(height: 1)
            }

            if expanded, let summary {
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ink.muted)
                    .lineSpacing(2)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Ink.hairline, lineWidth: 1)
                    )
            }
        }
    }
}


#if DEBUG
/// A way to render the pieces of this screen without a server behind them.
///
/// The bubbles are file-private and should stay that way; this is the one seam
/// out, and it exists because "it compiles" says nothing about whether a
/// restyle clipped a figure or lost a divider. `InsightsRenderTests` draws each
/// of these to a PNG so the layout can actually be looked at.
enum InsightsPreview {
    static func measuredWeek(_ snapshot: HealthSnapshot) -> some View {
        SnapshotBubble(snapshot: snapshot)
    }

    static func question(_ text: String) -> some View {
        UserBubble(text: text)
    }

    static func answer(_ turn: ChatTurn) -> some View {
        AnswerBubble(turn: turn, onFeedback: { _, _ in }, onAgain: { _ in })
    }

    static func pending(_ label: String) -> some View {
        PendingBubble(label: label)
    }

    /// A chip on its own. `ImageRenderer` will not draw the `ScrollView` the
    /// real ones sit in, so this is the only way to see one.
    static func chip(_ label: String) -> some View {
        Button(label) {}.buttonStyle(ChipStyle())
    }

    /// Needs a `@FocusState` to bind to, which only a view can own.
    struct ComposerHarness: View {
        let text: String
        let showsSuggestions: Bool
        @State private var question: String
        @FocusState private var focused: Bool

        init(text: String, showsSuggestions: Bool) {
            self.text = text
            self.showsSuggestions = showsSuggestions
            _question = State(initialValue: text)
        }

        var body: some View {
            Composer(
                question: $question, focused: $focused,
                showsSuggestions: showsSuggestions,
                suggestions: ["How is my sleep?", "Am I more active?"],
                isAsking: false, onSend: { _ in }, onWeeklyReview: {}
            )
        }
    }
}
#endif
