import Foundation

/// What the destination server reports it is holding.
///
/// This exists because the app is otherwise write-only: it knows what it read
/// from HealthKit and what it handed to the network, but not what actually
/// landed. Background sync fails quietly by design — a revoked token, a stale
/// pin, or background delivery dying after an OS update all look exactly like
/// "nothing has happened yet". Comparing local state against the server's own
/// account of itself is the only way to tell those apart from the phone.
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
