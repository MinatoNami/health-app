import Foundation

/// The server's health analysis and the explanations built on it.
///
/// Decoded from `/v1/analysis/snapshot` and `/v1/insights/ask` rather than
/// recomputed on the phone. That is not laziness: baselines, coverage grading,
/// and the deduplication rules underneath them are subtle enough that a second
/// implementation would drift, and a phone quietly disagreeing with the
/// dashboard about the same week is worse than either number alone.
///
/// Only the fields this app actually shows are declared. The payloads carry
/// more — per-day series, per-metric quality reports — and decoding them just to
/// discard them would mean a decode failure every time the server grew a field.

struct HealthSnapshot: Codable, Equatable {
    struct Window: Codable, Equatable {
        var value: Double?
        var validDays: Int
        var windowDays: Int
        /// Scored against how often the metric is *expected*, not against every
        /// calendar day — three weighings a week is full coverage for weight.
        var coverage: Double?

        enum CodingKeys: String, CodingKey {
            case value
            case validDays = "valid_days"
            case windowDays = "window_days"
            case coverage
        }
    }

    struct Comparison: Codable, Equatable, Identifiable {
        var metricSlug: String
        var label: String
        var unit: String
        var direction: String
        var current: Window
        var baseline: Window
        var change: Double?
        var changePct: Double?
        var significance: String
        var confidence: String
        var confidenceReason: String

        var id: String { metricSlug }

        /// Whether a comparison is worth showing as one at all.
        var isUsable: Bool { confidence != "insufficient" }

        /// Which way this moved, for wellness framing only. A metric with no
        /// better direction — weight, respiratory rate — deliberately gets
        /// neither colour: calling a weight change good or bad is a judgement
        /// this app has no business making.
        enum Tone { case good, watch, neutral }

        var tone: Tone {
            guard isUsable, let change, direction != "neutral", significance != "stable" else {
                return .neutral
            }
            let better = direction == "higher_better" ? change > 0 : change < 0
            return better ? .good : .watch
        }

        enum CodingKeys: String, CodingKey {
            case metricSlug = "metric_slug"
            case label, unit, direction, current, baseline, change
            case changePct = "change_pct"
            case significance, confidence
            case confidenceReason = "confidence_reason"
        }
    }

    struct Sleep: Codable, Equatable {
        var averageHours: Double?
        var typicalBedtime: String?
        var typicalWakeTime: String?
        var consistency: String
        var nightsRecorded: Int
        var windowDays: Int

        enum CodingKeys: String, CodingKey {
            case averageHours = "average_hours"
            case typicalBedtime = "typical_bedtime"
            case typicalWakeTime = "typical_wake_time"
            case consistency
            case nightsRecorded = "nights_recorded"
            case windowDays = "window_days"
        }
    }

    /// A metric that was recorded once and has stopped arriving.
    ///
    /// The failure mode this app exists to catch: nothing errors, the numbers
    /// just quietly stop. A gap is not a zero — a watch that was not worn is
    /// not a night without sleep.
    struct Stale: Codable, Equatable, Identifiable {
        var metricSlug: String
        var label: String
        var lastRecordedAt: String?
        var daysSince: Int?

        var id: String { metricSlug }

        enum CodingKeys: String, CodingKey {
            case metricSlug = "metric_slug"
            case label
            case lastRecordedAt = "last_recorded_at"
            case daysSince = "days_since"
        }
    }

    var asOf: String
    var metrics: [Comparison]
    var sleep: Sleep?
    var overallConfidence: String
    var metricsUnavailable: [String]
    var metricsNotSyncing: [Stale]?

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case metrics, sleep
        case overallConfidence = "overall_confidence"
        case metricsUnavailable = "metrics_unavailable"
        case metricsNotSyncing = "metrics_not_syncing"
    }
}

/// One generated answer, in the structured shape §12 of the integration notes
/// asks for. Structured rather than prose so it can be rendered, stored, and
/// checked — and so the safety layer can read what it says.
struct HealthInsight: Codable, Equatable {
    struct Observation: Codable, Equatable, Identifiable {
        var statement: String
        var evidence: String
        var confidence: String
        var id: String { statement }
    }

    struct Action: Codable, Equatable, Identifiable {
        var action: String
        var reason: String
        var timeframe: String
        var id: String { action }
    }

    var summary: String
    var periodExamined: String
    var observations: [Observation]
    var actions: [Action]
    var limitations: [String]
    var confidence: String
    var professionalReviewRecommended: Bool
    var professionalReviewReason: String?

    enum CodingKeys: String, CodingKey {
        case summary
        case periodExamined = "period_examined"
        case observations, actions, limitations, confidence
        case professionalReviewRecommended = "professional_review_recommended"
        case professionalReviewReason = "professional_review_reason"
    }
}

/// The escalation level, decided by rules on the server before any model runs.
///
/// Carried to the phone rather than re-derived here for the same reason as
/// everything else: one implementation, one answer. A phone that classified a
/// symptom differently from the server would be a second opinion nobody asked
/// for on the question where agreement matters most.
struct SafetyVerdict: Codable, Equatable {
    var level: String
    var reasons: [String]
    var blocked: Bool
    var blockedReason: String?

    var isElevated: Bool { level == "urgent" || level == "review_recommended" }

    var headline: String {
        switch level {
        case "urgent": return "Seek medical attention"
        case "review_recommended": return "Worth a professional review"
        case "coaching": return "Wellness coaching"
        default: return "Informational"
        }
    }

    enum CodingKeys: String, CodingKey {
        case level, reasons, blocked
        case blockedReason = "blocked_reason"
    }
}

struct InsightResult: Codable, Equatable {
    struct ModelInfo: Codable, Equatable {
        struct Destination: Codable, Equatable {
            var kind: String
            var description: String
        }

        var name: String
        var latencyMs: Int
        var toolRounds: Int
        var destination: Destination?

        enum CodingKeys: String, CodingKey {
            case name
            case latencyMs = "latency_ms"
            case toolRounds = "tool_rounds"
            case destination
        }
    }

    var question: String
    var answer: HealthInsight?
    var safety: SafetyVerdict
    var generated: Bool
    var error: String?
    var source: String?
    var model: ModelInfo?

    /// True when the answer came from reviewed guidance instead of the model,
    /// which is what happens for anything the safety rules call urgent.
    var isRuleBased: Bool { source == "safety_rules" }
}

/// Where health summaries get explained, and whether that is working.
struct InsightStatus: Codable, Equatable {
    struct Destination: Codable, Equatable {
        var kind: String
        var description: String
    }

    var enabled: Bool
    var reachable: Bool
    var model: String?
    var detail: String?
    var destination: Destination?
    var retentionDays: Int?

    var isReady: Bool { enabled && reachable }

    enum CodingKeys: String, CodingKey {
        case enabled, reachable, model, detail, destination
        case retentionDays = "retention_days"
    }
}
