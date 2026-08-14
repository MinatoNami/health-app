import Foundation

/// Conversations, and the turns inside them.
///
/// The phone used to ask one-off questions: a question went up, an answer came
/// back, and both were replaced by the next one. The server has stored these as
/// conversations for a while — the dashboard has had a sidebar, projects and
/// per-answer feedback — and the phone was the odd one out, holding a chat-shaped
/// screen over a stateless call.
///
/// These types are the server's, decoded rather than re-derived, for the reason
/// every other model here is: two implementations of "which turns belong to this
/// conversation" would drift, and a phone quietly disagreeing with the dashboard
/// about what was said is worse than either view alone.

/// Parses the timestamps Django sends.
///
/// `ISO8601DateFormatter` is the obvious tool and quietly the wrong one on its
/// own: Python's `isoformat()` emits *six* fractional digits, and
/// `.withFractionalSeconds` is only dependable for three. It returns nil rather
/// than throwing, so the failure looks like a decode error on an unrelated field
/// — which is a bad afternoon.
///
/// So: try it, and if that fails, cut the fractional part out and try again. The
/// sub-second precision is worthless here anyway; these dates group a list into
/// "Today" and "Yesterday".
enum ServerDate {
    private static let formatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()

    static func parse(_ raw: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: raw) { return date }
        }
        guard let dot = raw.firstIndex(of: "."),
              let end = raw[dot...].firstIndex(where: { $0 == "+" || $0 == "Z" || $0 == "-" })
        else { return nil }
        let trimmed = raw.replacingCharacters(in: dot..<end, with: "")
        return formatters.compactMap { $0.date(from: trimmed) }.first
    }

    /// A decoding strategy that keeps an unparseable date from failing the whole
    /// response. A conversation list is still worth showing with one odd
    /// timestamp in it.
    static let decodingStrategy = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let raw = try decoder.singleValueContainer().decode(String.self)
        return parse(raw) ?? .distantPast
    }
}

/// A folder of related conversations, with standing context they all inherit.
struct ChatProject: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var instructions: String
    var archived: Bool
    var sessionCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, instructions, archived
        case sessionCount = "session_count"
    }
}

/// One conversation, as it appears in a list.
struct ChatSession: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var projectId: Int?
    var archived: Bool
    var lastMessageAt: Date
    var messageCount: Int?
    var preview: String?
    /// Present once older turns have been folded into a written summary. The
    /// transcript still holds every message — compaction changes what the model
    /// is sent, never what was said.
    var summary: String?
    var summaryTurns: Int

    enum CodingKeys: String, CodingKey {
        case id, title, archived, preview, summary
        case projectId = "project_id"
        case lastMessageAt = "last_message_at"
        case messageCount = "message_count"
        case summaryTurns = "summary_turns"
    }

    /// Which heading this belongs under. Compared by calendar day rather than
    /// elapsed hours: something asked at 23:50 last night is "Yesterday" at
    /// 00:10, not "12 minutes ago".
    var bucket: String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: lastMessageAt),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2...7: return "Previous 7 days"
        case 8...30: return "Previous 30 days"
        default: return "Older"
        }
    }
}

/// One stored question and the answer that came back.
struct ChatMessage: Codable, Equatable, Identifiable {
    var id: Int
    var sessionId: String?
    var question: String
    var answer: HealthInsight?
    var safety: SafetyVerdict?
    var modelName: String
    var latencyMs: Int
    var error: String
    var createdAt: Date
    /// 1, -1, or absent. What you made of the answer.
    var rating: Int?
    var note: String

    enum CodingKeys: String, CodingKey {
        case id, question, answer, safety, error, rating, note
        case sessionId = "session_id"
        case modelName = "model_name"
        case latencyMs = "latency_ms"
        case createdAt = "created_at"
    }
}

/// One conversation with everything said in it.
struct ChatTranscript: Codable, Equatable {
    struct Context: Codable, Equatable {
        var limitTokens: Int
        var lastPromptTokens: Int
        var pendingTurns: Int

        /// How full the model's context is, as a fraction. Measured — this is
        /// what the server actually counted for the last prompt, not an
        /// estimate.
        var used: Double? {
            guard limitTokens > 0, lastPromptTokens > 0 else { return nil }
            return Double(lastPromptTokens) / Double(limitTokens)
        }

        enum CodingKeys: String, CodingKey {
            case limitTokens = "limit_tokens"
            case lastPromptTokens = "last_prompt_tokens"
            case pendingTurns = "pending_turns"
        }
    }

    var id: String
    var title: String
    var projectId: Int?
    var summary: String?
    var summaryTurns: Int
    var messages: [ChatMessage]
    var retentionDays: Int?
    var context: Context?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, messages, context
        case projectId = "project_id"
        case summaryTurns = "summary_turns"
        case retentionDays = "retention_days"
    }
}

/// A page of conversations.
struct ChatSessionPage: Codable, Equatable {
    var sessions: [ChatSession]
    var total: Int
}

struct ChatProjectList: Codable, Equatable {
    var projects: [ChatProject]
}

/// What a delete removed. Reported rather than assumed: a chat that vanished
/// from the list while its questions stayed in the database is the kind of
/// deletion that is worse than none.
struct DeletionResult: Codable, Equatable {
    var status: String
    var messagesDeleted: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case messagesDeleted = "messages_deleted"
    }
}

/// What the server did with a compaction request.
struct CompactionResult: Codable, Equatable {
    var compacted: Bool
    var turns: Int
    var reason: String?
    var session: ChatSession?
}

/// One exchange as the transcript draws it: the question, and whatever came
/// back — which may be nothing yet.
///
/// A single type for both halves rather than a flat list of bubbles, because a
/// question without its answer is never a thing this screen shows. It also
/// means the rating controls have one place to live: alongside the answer they
/// are about, on the same row that produced them.
struct ChatTurn: Identifiable, Equatable {
    /// Stable across the pending → answered transition, so SwiftUI animates the
    /// bubble filling in rather than replacing one row with another.
    let id: UUID
    var question: String
    var answer: HealthInsight?
    var safety: SafetyVerdict?
    var error: String?
    var modelName: String?
    var latencyMs: Int?
    var isPending: Bool
    var isRuleBased: Bool
    /// The stored row this came from. Absent while pending, and for a question
    /// asked with "don't remember this" — there is nothing to attach a rating
    /// to in either case.
    var storedId: Int?
    var rating: Int?
    var note: String

    init(
        id: UUID = UUID(),
        question: String,
        answer: HealthInsight? = nil,
        safety: SafetyVerdict? = nil,
        error: String? = nil,
        modelName: String? = nil,
        latencyMs: Int? = nil,
        isPending: Bool = false,
        isRuleBased: Bool = false,
        storedId: Int? = nil,
        rating: Int? = nil,
        note: String = ""
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.safety = safety
        self.error = error
        self.modelName = modelName
        self.latencyMs = latencyMs
        self.isPending = isPending
        self.isRuleBased = isRuleBased
        self.storedId = storedId
        self.rating = rating
        self.note = note
    }

    /// A stored message, as a turn on screen.
    ///
    /// The stored row keeps the model name and latency as columns where a live
    /// answer nests them, because a turn that never reached a model has no such
    /// object to store. Rebuilding it here keeps one renderer for both paths —
    /// a second "historical answer" view would drift from the live one inside a
    /// release.
    init(stored: ChatMessage) {
        self.init(
            question: stored.question.isEmpty ? "Weekly review" : stored.question,
            answer: stored.answer,
            safety: stored.safety,
            error: stored.error.isEmpty ? nil : stored.error,
            modelName: stored.modelName.isEmpty ? nil : stored.modelName,
            latencyMs: stored.latencyMs,
            // Not stored, so inferred from the one thing that produces it: the
            // safety layer answering an urgent question without calling a model.
            isRuleBased: stored.safety?.level == "urgent" && stored.modelName.isEmpty,
            storedId: stored.id,
            rating: stored.rating,
            note: stored.note
        )
    }

    /// A live answer landing on a turn that was pending.
    mutating func complete(with result: InsightResult) {
        answer = result.answer
        safety = result.safety
        error = result.error
        modelName = result.model?.name
        latencyMs = result.model?.latencyMs
        isRuleBased = result.isRuleBased
        storedId = result.turnId
        isPending = false
    }
}
