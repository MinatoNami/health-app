import SwiftUI

/// The landing screen, rebuilt around one idea: say the thing, then show the
/// evidence for it.
///
/// What this replaces — `StatusView` — was Health's idiom: six metrics at equal
/// weight, each a name and a number and a percentage. That is the right shape
/// for a database browser and the wrong one here, because this app has already
/// done the arithmetic and has an opinion. A screen with no opinion makes the
/// reader form one from six equal rows every morning.
///
/// So the order is: a sentence, the coverage it rests on, only the metrics that
/// actually moved, everything steady compressed to chips, and anything that has
/// *stopped* given its own callout. On a week where nothing moved this screen
/// is nearly empty, which is exactly the behaviour `StatusView`'s own docstring
/// argued for — "healthy days say almost nothing, which is what makes the bad
/// day visible."
struct TodayView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var authorization: HealthAuthorization
    @EnvironmentObject private var engine: SyncEngine

    /// A change under this is noise, not news. The server already grades
    /// significance; this is the second gate, because "stable" still admits
    /// small movements and three of those are not a headline.
    private static let moverThreshold = 5.0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    header

                    // Onboarding covers the first run. This is the *second*
                    // case: someone who skipped it, or declined at the prompt.
                    // It cannot tell those apart — read authorisation is
                    // deliberately opaque, and an empty store looks exactly
                    // like a refused one — so it says neither.
                    if !authorization.hasRequested, !services.needsOnboarding {
                        grantAccessCard
                    }

                    // Above the figures, because when this is showing the
                    // figures below it may be days old — and the difference
                    // between "you trained less" and "nothing has uploaded
                    // since Tuesday" is the whole point of saying so.
                    if let banner = runningBanner {
                        SyncBanner(state: banner) { services.selectedTab = .data }
                    }

                    if let snapshot = engine.snapshot {
                        if isBuildingBaseline(snapshot) {
                            buildingLead(snapshot)
                            recordedSoFar(snapshot)
                        } else {
                            lead(snapshot)
                            if !movers(snapshot).isEmpty { moversSection(snapshot) }
                            if !steady(snapshot).isEmpty { steadySection(snapshot) }
                            ForEach(stale(snapshot)) { staleCallout($0) }
                        }
                    } else {
                        placeholder
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(Ink.ground)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { askBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { syncButton } }
            .navigationDestination(for: HealthSnapshot.Comparison.self) { comparison in
                MetricDetailView(comparison: comparison)
            }
        }
        .tint(Ink.accent)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.figure(13, weight: .medium))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Ink.faint)
            Spacer()
            syncState
        }
    }

    private var syncState: some View {
        HStack(spacing: 6) {
            Circle()
                // Green means "something arrived", not "a token exists". The
                // two came apart immediately: signed in on a simulator with no
                // Health data showed a teal dot beside the words "not synced".
                .fill(engine.settings.lastFullSyncAt == nil ? Ink.faint : Ink.measured)
                .frame(width: 6, height: 6)
            Text(lastSyncedLabel)
                .font(.figure(12, weight: .regular))
                .foregroundStyle(Ink.faint)
        }
        .accessibilityElement(children: .combine)
    }

    private var lastSyncedLabel: String {
        guard let at = engine.settings.lastFullSyncAt else { return "not synced" }
        return "synced " + at.formatted(date: .omitted, time: .shortened)
    }

    private var syncButton: some View {
        Button {
            Task { await engine.syncAll(reason: "manual") }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .disabled(engine.phase.isRunning)
        .accessibilityLabel("Sync now")
    }

    // MARK: - The lead

    /// One sentence, built from what actually moved.
    ///
    /// Assembled on the phone from figures the server computed — no new
    /// arithmetic, only wording. It never claims a cause: "you trained harder
    /// *and* slept longer", never "because".
    private func lead(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(headline(snapshot))
                .font(.lead)
                .kerning(-0.5)
                .lineSpacing(2)
                // Dimmed when nothing is reaching the server. The numbers are
                // still true — they were measured — they are just not about
                // this week any more, and rendering them at full strength next
                // to a failure banner invites reading them as current.
                .foregroundStyle(isStalled ? Ink.secondary : Ink.primary)
                .fixedSize(horizontal: false, vertical: true)

            if isStalled {
                Text("Figures through \(readableDay(snapshot.asOf)) — the last day that reached the server.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ink.absentInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let widest = snapshot.metrics.first(where: { $0.isUsable }) {
                CoverageSummary(
                    validDays: widest.current.validDays,
                    windowDays: widest.current.windowDays
                )
            }
        }
    }

    // MARK: - The first week

    /// True while there is data but nothing worth comparing yet.
    ///
    /// Week one is the state this app's whole idiom has nothing to say in:
    /// every figure it shows is "your last 7 days against your own preceding
    /// 28", and on day three there is no preceding 28. Without this branch the
    /// screen fell through to "Nothing moved much against your last four
    /// weeks" — which is not a cautious way of saying *no baseline yet*, it is
    /// a claim of stability that was never measured.
    private func isBuildingBaseline(_ snapshot: HealthSnapshot) -> Bool {
        !snapshot.metrics.isEmpty && snapshot.metrics.allSatisfy { !$0.isUsable }
    }

    /// The metric with the most days behind it, usable or not — the honest
    /// denominator for "how far along is this".
    private func widest(_ snapshot: HealthSnapshot) -> HealthSnapshot.Comparison? {
        snapshot.metrics.max { $0.current.validDays < $1.current.validDays }
    }

    private func buildingLead(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Not enough days yet to compare anything.")
                .font(.lead)
                .kerning(-0.5)
                .lineSpacing(2)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let widest = widest(snapshot) {
                CoverageSummary(
                    validDays: widest.current.validDays,
                    windowDays: widest.current.windowDays
                )
            }

            Text("A week against your own baseline needs a baseline. Yours is being built — comparisons start appearing once there are enough days on both sides of the window.")
                .font(.system(size: 13.5))
                .lineSpacing(2)
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What has actually been recorded, with the day count attached.
    ///
    /// Deliberately *not* labelled "yesterday". The value is the mean over
    /// however many days exist, and on two days that is a mean of two — calling
    /// it a single day would be the same species of lie as showing it as a
    /// weekly average.
    private func recordedSoFar(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recorded so far").sectionLabelStyle()
            VStack(spacing: 0) {
                ForEach(Array(recorded(snapshot).enumerated()), id: \.element.id) { index, metric in
                    if index > 0 { Divider().overlay(Ink.divider) }
                    HStack {
                        Text(MetricStyle.shortLabel(metric.metricSlug, fallback: metric.label))
                            .font(.system(size: 13.5))
                            .foregroundStyle(Ink.secondary)
                        Spacer()
                        Text(MetricFormat.value(metric.current.value, slug: metric.metricSlug))
                            .font(.figure(13.5))
                            .foregroundStyle(Ink.primary)
                        Text(MetricStyle.unit(metric.unit, slug: metric.metricSlug))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Ink.faint)
                        Text("· \(metric.current.validDays)d")
                            .font(.figure(11.5, weight: .regular))
                            .foregroundStyle(Ink.faint)
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 13)
                }
            }
            .cardStyle()

            Text("Averages over the days recorded, not single readings. One day is not a trend and is not shown as one.")
                .font(.system(size: 12.5))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `as_of` arrives as a plain `yyyy-MM-dd`. Fine on the wire, wrong in a
    /// sentence — "Figures through 2026-08-25" reads like a log line.
    private func readableDay(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = .current
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// True when delivery is broken rather than merely quiet.
    private var isStalled: Bool {
        guard let banner = runningBanner else { return false }
        switch banner {
        case .failed, .stale, .uploadingOff: return true
        case .locked, .running: return false
        }
    }

    private func recorded(_ snapshot: HealthSnapshot) -> [HealthSnapshot.Comparison] {
        snapshot.metrics.filter { ($0.current.validDays) > 0 }
    }

    /// Whatever the sync layer wants said, if anything. Nil on an ordinary day
    /// — a healthy app says nothing here, which is what makes the bad day
    /// visible.
    ///
    /// No invented progress figures: nothing in this app knows how long a
    /// backfill has to go, so it reports the phase it is actually in.
    private var runningBanner: SyncBanner.State? {
        SyncBanner.state(
            phase: engine.phase,
            lastSyncedAt: engine.settings.lastFullSyncAt,
            pendingBatches: engine.pendingBatches,
            uploadEnabled: engine.settings.sink.enabled
        )
    }

    private func headline(_ snapshot: HealthSnapshot) -> String {
        let moved = movers(snapshot)
        guard !moved.isEmpty else {
            return "Nothing moved much against your last four weeks."
        }
        let phrases = moved.prefix(2).map { phrase(for: $0) }
        let joined = phrases.count == 2 ? "\(phrases[0]) and \(phrases[1])" : phrases[0]
        return "You \(joined) than your last four weeks."
    }

    private func phrase(for c: HealthSnapshot.Comparison) -> String {
        let up = (c.change ?? 0) > 0
        switch c.metricSlug {
        case "apple_exercise_time": return up ? "trained harder" : "trained less"
        case "sleep_analysis": return up ? "slept longer" : "slept less"
        case "step_count": return up ? "moved more" : "moved less"
        case "resting_heart_rate": return up ? "had a higher resting heart rate" : "had a lower resting heart rate"
        case "heart_rate_variability_sdnn": return up ? "recovered better" : "recovered less"
        default: return "\(up ? "saw more" : "saw less") \(c.label.lowercased())"
        }
    }

    // MARK: - Sections

    private func movers(_ snapshot: HealthSnapshot) -> [HealthSnapshot.Comparison] {
        snapshot.metrics
            .filter { $0.isUsable && abs($0.changePct ?? 0) >= Self.moverThreshold }
            .sorted { abs($0.changePct ?? 0) > abs($1.changePct ?? 0) }
    }

    private func steady(_ snapshot: HealthSnapshot) -> [HealthSnapshot.Comparison] {
        snapshot.metrics.filter { $0.isUsable && abs($0.changePct ?? 0) < Self.moverThreshold }
    }

    private func stale(_ snapshot: HealthSnapshot) -> [HealthSnapshot.Stale] {
        snapshot.metricsNotSyncing ?? []
    }

    private func moversSection(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What moved").sectionLabelStyle()
            VStack(spacing: 4) {
                ForEach(movers(snapshot)) { MoverRow(comparison: $0) }
            }
        }
    }

    private func steadySection(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Steady").sectionLabelStyle()
            // A wrapping run of chips. `Layout` would be tidier; this keeps the
            // file free of one for three items.
            FlowRow(spacing: 8) {
                ForEach(steady(snapshot)) { comparison in
                    NavigationLink(value: comparison) {
                        SteadyChip(comparison: comparison)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func staleCallout(_ item: HealthSnapshot.Stale) -> some View {
        Button {
            services.selectedTab = .data
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Ink.absent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(staleTitle(item))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.absentInk)
                    Text("Not zero — absent. Nothing has been recorded since then.")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .background(Ink.absent.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Ink.absent.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func staleTitle(_ item: HealthSnapshot.Stale) -> String {
        guard let days = item.daysSince else { return "\(item.label) has stopped arriving" }
        if days <= 0 { return "\(item.label) arrived today, but not this week" }
        if days < 14 { return "\(item.label) stopped \(days) days ago" }
        return "\(item.label) stopped \(days / 7) weeks ago"
    }

    // MARK: - Other states

    private var grantAccessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grant Health access to begin")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Text("You'll be asked once per data type, ever. Choose the groups first — afterwards, changing your mind means a trip to Settings.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Request Health Access") {
                Task { await authorization.requestAuthorization() }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Ink.ground)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(Ink.accent, in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle()
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(engine.isSignedIn ? "No reading yet." : "Sign in to see your week.")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            if let error = engine.snapshotError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.absentInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var askBar: some View {
        Button {
            services.selectedTab = .insights
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.accent)
                // Not disabled while the baseline builds. The server answers
                // a thin week honestly — that is what the confidence grades are
                // for — and "why is there nothing here yet?" is a fair question
                // to want answered on day two.
                Text(engine.snapshot.map(isBuildingBaseline) == true
                     ? "Ask — answers will say how thin the data is"
                     : "Ask about your health data")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.faint)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 48)
            .padding(.horizontal, 15)
            .background(Ink.field)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background(Ink.ground)
    }
}

// MARK: - Pieces

private struct MoverRow: View {
    let comparison: HealthSnapshot.Comparison

    var body: some View {
        NavigationLink(value: comparison) {
            HStack(spacing: 13) {
                Capsule()
                    .fill(tint)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(MetricStyle.shortLabel(comparison.metricSlug, fallback: comparison.label))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Ink.primary)
                        Spacer(minLength: 0)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(MetricFormat.value(comparison.current.value, slug: comparison.metricSlug))
                                .font(.figure(24))
                                .foregroundStyle(Ink.primary)
                            Text(MetricStyle.unit(comparison.unit, slug: comparison.metricSlug))
                                .font(.system(size: 12))
                                .foregroundStyle(Ink.muted)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(MetricFormat.change(comparison.changePct))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                        Text("on \(MetricFormat.value(comparison.baseline.value, slug: comparison.metricSlug)) \(MetricStyle.unit(comparison.unit, slug: comparison.metricSlug))")
                            .font(.system(size: 13))
                            .foregroundStyle(Ink.muted)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.hairline)
            }
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Neutral-direction metrics get no colour at all. Calling a weight change
    /// good or bad is a judgement this app has no business making, and the
    /// server already encodes that as `direction == "neutral"`.
    private var tint: Color {
        switch comparison.tone {
        case .good: return Ink.measured
        case .watch: return Ink.absent
        case .neutral: return Ink.faint
        }
    }
}

private struct SteadyChip: View {
    let comparison: HealthSnapshot.Comparison

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(MetricStyle.shortLabel(comparison.metricSlug, fallback: comparison.label))
                .font(.system(size: 12))
                .foregroundStyle(Ink.muted)
            Text(MetricFormat.value(comparison.current.value, slug: comparison.metricSlug))
                .font(.figure(13))
                .foregroundStyle(Ink.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Ink.raised)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Ink.hairline, lineWidth: 1)
        )
    }
}

/// A wrapping HStack. SwiftUI has no built-in one before the `Layout` protocol
/// gets involved, and three chips do not justify a custom `Layout`.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
