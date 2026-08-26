import Foundation

/// What the destination server reports it is holding.
///
/// This exists because the app is otherwise write-only: it knows what it read
/// from HealthKit and what it handed to the network, but not what actually
/// landed. Background sync fails quietly by design — a revoked token, a stale
/// pin, or background delivery dying after an OS update all look exactly like
/// "nothing has happened yet". Comparing local state against the server's own
/// account of itself is the only way to tell those apart from the phone.
/// Per-metric high-water marks, for reconciling anchors before a sync.
///
/// Separate from `ServerStatus` because the two answer different questions and
/// have different correctness requirements. `ServerStatus` is for a person to
/// read and is capped at the top 60 metrics; this one has to be complete, since
/// a metric missing from it is taken as evidence the server lost that type and
/// triggers a full re-read.
struct ServerCoverage: Codable, Equatable {
    struct Metric: Codable, Equatable {
        var count: Int
        var latestSampleAt: String?
        var latestSampleEnd: String?
        var latestRecordedAt: String?

        /// The newest sample's *start*. Not what the client's own high-water
        /// mark measures — see `latestSampleEndDate`.
        var latestSampleDate: Date? { latestSampleAt.flatMap(Timestamps.parse) }

        /// The newest sample's *end*, which is the figure an anchor's
        /// `lastSampleEnd` is comparable with. Optional because a server older
        /// than this field will not send it, and guessing would reintroduce
        /// exactly the bug it exists to fix.
        var latestSampleEndDate: Date? { latestSampleEnd.flatMap(Timestamps.parse) }

        enum CodingKeys: String, CodingKey {
            case count
            case latestSampleAt = "latest_sample_at"
            case latestSampleEnd = "latest_sample_end"
            case latestRecordedAt = "latest_recorded_at"
        }
    }

    /// Keyed by metric slug.
    var metrics: [String: Metric]
    var generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case metrics
        case generatedAt = "generated_at"
    }
}

struct ServerStatus: Codable, Equatable {
    struct Metric: Codable, Equatable, Identifiable {
        var metricSlug: String
        var count: Int
        var latestSampleAt: String?
        var unit: String?

        var id: String { metricSlug }

        var latestSampleDate: Date? {
            latestSampleAt.flatMap(Timestamps.parse)
        }

        /// Matches the 48-hour window the Status tab already uses for local
        /// staleness, so the two screens agree on what "stale" means.
        var isStale: Bool {
            guard let date = latestSampleDate else { return true }
            return Date().timeIntervalSince(date) > 48 * 3600
        }

        enum CodingKeys: String, CodingKey {
            case metricSlug = "metric_slug"
            case count
            case latestSampleAt = "latest_sample_at"
            case unit
        }
    }

    struct DeviceSummary: Codable, Equatable, Identifiable {
        var deviceId: String
        var label: String?
        var appVersion: String?
        var lastSeenAt: String?
        var recordCount: Int
        var latestSampleAt: String?

        var id: String { deviceId }

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case label
            case appVersion = "app_version"
            case lastSeenAt = "last_seen_at"
            case recordCount = "record_count"
            case latestSampleAt = "latest_sample_at"
        }
    }

    var recordsTotal: Int
    var recordsDeleted: Int
    var batches: [String: Int]
    var lastBatchAt: String?
    var lastBatchRecords: Int
    var devices: [DeviceSummary]
    var metrics: [Metric]
    var generatedAt: String?
    var cached: Bool?

    /// One metric's daily series, as returned by `/v1/analytics/overview`.
    ///
    /// Decoded from the same endpoint the web dashboard uses rather than
    /// recomputed locally: the deduplication rules there are subtle enough
    /// (Apple rollups preferred over raw sums, sleep summed from durations)
    /// that a second implementation would drift and quietly disagree.
    struct Series: Codable, Equatable, Identifiable {
        struct Point: Codable, Equatable, Identifiable {
            var date: String
            var value: Double
            var source: String?

            var id: String { date }
            /// Day-granularity, so a plain calendar parse is right here — the
            /// per-sample offsets that matter elsewhere are already applied
            /// server-side when the day buckets are built.
            ///
            /// Optional rather than falling back to a placeholder date: this
            /// feeds a chart's x-axis, and one `.distantPast` among current days
            /// stretches the domain across two millennia, which squeezes the real
            /// data into an invisible sliver and costs a visible layout hang.
            /// A day that cannot be placed on the axis is dropped instead.
            var parsedDay: Date? {
                ISO8601DateFormatter.calendarDay.date(from: date + "T00:00:00Z")
            }
            var day: Date { parsedDay ?? .distantPast }
            /// True when this day was summed from raw samples rather than an
            /// Apple-deduplicated rollup, so it may read high.
            var isEstimated: Bool { source == "raw_sum" }
        }

        var metricSlug: String
        var points: [Point]
        var unit: String?
        var cumulative: Bool?
        var mayDoubleCount: Bool

        var id: String { metricSlug }

        enum CodingKeys: String, CodingKey {
            case metricSlug = "metric_slug"
            case points
            case unit
            case cumulative
            case mayDoubleCount = "may_double_count"
        }
    }

    var lastBatchDate: Date? { lastBatchAt.flatMap(Timestamps.parse) }
    var storedBatches: Int { batches["stored"] ?? 0 }
    var failedBatches: Int { batches["failed"] ?? 0 }
    var staleMetrics: [Metric] { metrics.filter(\.isStale) }

    enum CodingKeys: String, CodingKey {
        case recordsTotal = "records_total"
        case recordsDeleted = "records_deleted"
        case batches
        case lastBatchAt = "last_batch_at"
        case lastBatchRecords = "last_batch_records"
        case devices
        case metrics
        case generatedAt = "generated_at"
        case cached
    }
}

/// Response of `/v1/analytics/overview` — the same payload the web dashboard
/// renders, so the two can never tell different stories.
struct AnalyticsOverview: Codable, Equatable {
    var from: String
    var to: String
    var charts: [ServerStatus.Series]

    /// Headline metrics worth a chart on the phone, in display order. A short
    /// list on purpose: the phone is for "is this working and roughly what does
    /// it look like", not for exploration — that is what the dashboard is.
    static let featured = ["step_count", "heart_rate", "active_energy_burned", "sleep_analysis"]

    func series(_ slug: String) -> ServerStatus.Series? {
        charts.first { $0.metricSlug == slug }
    }
}

extension ISO8601DateFormatter {
    /// Dedicated instance: these are date-only strings, and reusing the
    /// fractional-seconds parser on them just fails.
    static let calendarDay: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
