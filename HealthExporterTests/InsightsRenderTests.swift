import SwiftUI
import XCTest
@testable import HealthExporter

/// Draws the Insights components to PNGs so a restyle can be looked at.
///
/// Not assertions about pixels — those break on every font tweak and teach you
/// nothing. These render the pieces at a real phone width against the real
/// ground colour and write them out, so the question "did that clip, and is the
/// column still aligned" has an answer that does not need a signed-in device
/// and a running model. The size checks are only a guard against a view that
/// collapsed to nothing or ran away vertically.
@MainActor
final class InsightsRenderTests: XCTestCase {
    private static let width: CGFloat = 350   // 390pt board minus the 20pt gutters

    private var outputDirectory: URL {
        let base = ProcessInfo.processInfo.environment["INSIGHTS_RENDER_DIR"]
            ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base)
    }

    private func render(_ name: String, _ view: some View) throws -> CGSize {
        let renderer = ImageRenderer(
            content: view
                .frame(width: Self.width)
                .padding(20)
                .background(Ink.ground)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "\(name) rendered nothing")
        let data = try XCTUnwrap(image.pngData())
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
        return image.size
    }

    // MARK: - Fixtures. Invented numbers; no real record goes near a test.

    private func window(_ value: Double, valid: Int = 7, of days: Int = 7) -> HealthSnapshot.Window {
        .init(value: value, validDays: valid, windowDays: days, coverage: Double(valid) / Double(days))
    }

    private func comparison(
        _ slug: String, _ label: String, _ unit: String, _ direction: String,
        current: Double, baseline: Double, pct: Double, valid: Int = 7
    ) -> HealthSnapshot.Comparison {
        .init(
            metricSlug: slug, label: label, unit: unit, direction: direction,
            current: window(current, valid: valid), baseline: window(baseline),
            change: current - baseline, changePct: pct,
            significance: "moved", confidence: "high", confidenceReason: "7 of 7 days"
        )
    }

    private var snapshot: HealthSnapshot {
        HealthSnapshot(
            asOf: "2026-08-27",
            metrics: [
                comparison("step_count", "Steps", "steps", "higher_better",
                           current: 12_340, baseline: 9_350, pct: 32),
                comparison("sleep_analysis", "Sleep", "hr", "higher_better",
                           current: 7.0, baseline: 6.4, pct: 10),
                comparison("resting_heart_rate", "Resting HR", "bpm", "lower_better",
                           current: 58, baseline: 61, pct: -5),
                comparison("body_mass", "Weight", "kg", "neutral",
                           current: 76.0, baseline: 77.5, pct: -2, valid: 3),
            ],
            sleep: nil,
            overallConfidence: "high",
            metricsUnavailable: [],
            metricsNotSyncing: nil
        )
    }

    private var answeredTurn: ChatTurn {
        ChatTurn(
            question: "Why did my sleep improve this week?",
            answer: HealthInsight(
                summary: """
                    Sleep rose from 6.4 to 7.0 hours a night. The clearest thing that changed \
                    alongside it is bedtime — a median 41 minutes earlier than the preceding \
                    four weeks. Wake time barely moved.
                    """,
                periodExamined: "19–25 Aug",
                observations: [
                    .init(statement: "Exercise also rose sharply over the same days. This data cannot separate the two.",
                          evidence: "Exercise minutes 58/day vs 31/day baseline",
                          confidence: "high"),
                    .init(statement: "Bedtime moved earlier on six of seven nights.",
                          evidence: "Median bedtime 23:14 vs 23:55",
                          confidence: "moderate"),
                ],
                actions: [],
                limitations: [],
                confidence: "high",
                professionalReviewRecommended: false,
                professionalReviewReason: nil
            ),
            modelName: "qwen3-32b",
            latencyMs: 24_000,
            isPending: false,
            storedId: 1,
            createdAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
    }

    // MARK: - Renders

    func testMeasuredWeekRenders() throws {
        let size = try render("insights-measured-week", InsightsPreview.measuredWeek(snapshot))
        XCTAssertGreaterThan(size.height, 200, "the card collapsed")
        XCTAssertLessThan(size.height, 700, "the card ran away vertically")
    }

    func testQuestionBubbleRenders() throws {
        let size = try render("insights-question",
                              InsightsPreview.question("Why did my sleep improve this week?"))
        XCTAssertGreaterThan(size.height, 60)
    }

    func testAnswerRenders() throws {
        let size = try render("insights-answer", InsightsPreview.answer(answeredTurn))
        XCTAssertGreaterThan(size.height, 300, "the answer or its evidence card is missing")
    }

    /// What this can and cannot show, stated because the images are misleading
    /// otherwise: `ImageRenderer` refuses to draw a `TextField` — it paints a
    /// yellow "unsupported" bar in its place — and it draws a `ScrollView` as
    /// nothing at all, which is where the suggestion chips live. So these two
    /// verify the pill, its border, and the send button flipping from inert
    /// grey to accent. The field's own text and the chip row are not in them,
    /// and `testChipRenders` covers the chip separately.
    func testComposerPillAndSendButtonRender() throws {
        let empty = try render("insights-composer-empty",
                               InsightsPreview.ComposerHarness(text: "", showsSuggestions: true))
        let armed = try render("insights-composer-armed",
                               InsightsPreview.ComposerHarness(text: "Why did my sleep improve?",
                                                               showsSuggestions: false))
        XCTAssertGreaterThan(empty.height, 60, "the pill collapsed")
        XCTAssertGreaterThan(armed.height, 60)
    }

    func testChipRenders() throws {
        let size = try render("insights-chip", InsightsPreview.chip("Why did sleep improve?"))
        XCTAssertGreaterThan(size.height, 60, "a 40pt chip plus 20pt padding either side")
    }

    // MARK: - The chat drawer
    //
    // Same limits: the sectioned `List` and the search field are not drawable,
    // so these cover the row and the retention footer, which are the two pieces
    // the restyle actually rewrote.

    func testChatRowRenders() throws {
        let size = try render(
            "chat-row",
            VStack(alignment: .leading, spacing: 14) {
                ChatHistoryPreview.row("Why did sleep improve?",
                                       ago: Date().addingTimeInterval(-2 * 3600))
                ChatHistoryPreview.row("What changed after the trip?",
                                       ago: Date().addingTimeInterval(-26 * 3600), compacted: 3)
            }
        )
        XCTAssertGreaterThan(size.height, 80)
    }

    func testRetentionFooterOnlyPromisesWhatTheServerConfirms() throws {
        let size = try render(
            "chat-retention",
            VStack(alignment: .leading, spacing: 18) {
                ChatHistoryPreview.footer(retentionDays: 30, keepRated: true)
                ChatHistoryPreview.footer(retentionDays: 30, keepRated: false)
            }
        )
        XCTAssertGreaterThan(size.height, 80)
    }

    func testPendingRenders() throws {
        let size = try render("insights-pending", InsightsPreview.pending("Reading your summaries"))
        XCTAssertGreaterThan(size.height, 40)
    }
}
