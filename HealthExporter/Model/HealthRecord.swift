import Foundation

/// The canonical wire record. One flat shape for every kind of HealthKit datum.
///
/// Flat beats faithful: a workflow engine wants uniform rows, not a
/// discriminated union mirroring HealthKit's class hierarchy. Kind-specific
/// detail lives in `extra` rather than in variant top-level shapes.
///
/// Timestamps are pre-formatted strings rather than `Date` because the correct
/// UTC offset is per-sample (from `HKMetadataKeyTimeZone` when present), and a
/// single encoder-wide date strategy cannot express that.
struct HealthRecord: Codable, Identifiable {
    enum Kind: String, Codable {
        case quantity
        case category
        case sleep
        case workout
        case correlation
        case statistic
        case characteristic
        case delete
    }

    enum Aggregation: String, Codable {
        /// Value accrues over `start`..`end`; summing across samples is valid.
        case cumulative
        /// Value is an instantaneous reading; summing is meaningless.
        case discrete
    }

    struct Source: Codable, Equatable {
        var name: String?
        var bundleId: String?
        var productType: String?
        var osVersion: String?

        enum CodingKeys: String, CodingKey {
            case name
            case bundleId = "bundle_id"
            case productType = "product_type"
            case osVersion = "os_version"
        }
    }

    /// HealthKit sample UUID. Stable across reads, which is what makes
    /// server-side upserts idempotent for free.
    var id: String
    var kind: Kind
    /// Raw HealthKit identifier, e.g. `HKQuantityTypeIdentifierHeartRate`.
    var metric: String
    /// Stable snake_case slug, e.g. `heart_rate`. Convenient for column names.
    var metricSlug: String
    var value: Double?
    /// Always shipped alongside `value`. Without it the number is meaningless
    /// and a unit change becomes silent data corruption.
    var unit: String?
    /// Human-readable enum name for category samples, e.g. `asleepREM`.
    var valueLabel: String?
    var start: String
    var end: String
    /// IANA zone when known, preferring the sample's own recorded timezone.
    var tz: String?
    var aggregation: Aggregation?
    var source: Source?
    var device: String?
    var metadata: [String: JSONValue]?
    /// Kind-specific fields: workout details, correlation components, etc.
    var extra: [String: JSONValue]?
    var recordedAt: String
    var deletedAt: String?
    var schemaVersion: Int = HealthRecord.currentSchemaVersion

    static let currentSchemaVersion = 1

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case metric
        case metricSlug = "metric_slug"
        case value
        case unit
        case valueLabel = "value_label"
        case start
        case end
        case tz
        case aggregation
        case source
        case device
        case metadata
        case extra
        case recordedAt = "recorded_at"
        case deletedAt = "deleted_at"
        case schemaVersion = "schema_version"
    }

    /// Tombstone for a sample removed from HealthKit. Anchored queries report
    /// deletions by UUID only — no type information — so `metric` is unknown.
    /// Ignoring these permanently diverges your store from Health.
    static func deletion(uuid: UUID, at date: Date = Date()) -> HealthRecord {
        let stamp = Timestamps.iso8601(date)
        return HealthRecord(
            id: uuid.uuidString,
            kind: .delete,
            metric: "unknown",
            metricSlug: "unknown",
            start: stamp,
            end: stamp,
            recordedAt: stamp,
            deletedAt: stamp
        )
    }
}

/// First line of every batch file. Lets the server validate completeness and
/// dedupe by `batch_id` without parsing the body.
struct BatchHeader: Codable {
    var kind: String = "batch_header"
    var batchId: String
    var deviceId: String
    var recordCount: Int
    var windowFrom: String?
    var windowTo: String?
    var appVersion: String
    var schemaVersion: Int = HealthRecord.currentSchemaVersion
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case kind
        case batchId = "batch_id"
        case deviceId = "device_id"
        case recordCount = "record_count"
        case windowFrom = "window_from"
        case windowTo = "window_to"
        case appVersion = "app_version"
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
    }
}
