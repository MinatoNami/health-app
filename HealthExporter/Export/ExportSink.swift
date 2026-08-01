import Foundation

/// Where batches go once they're written.
///
/// The uploader sits behind this protocol so v1 can ship as a file exporter and
/// gain an HTTP destination later without touching the read, normalize, or spool
/// layers. `HTTPSink` below is a complete implementation of the contract in
/// docs/ARCHITECTURE.md — it just needs a base URL and a token.
protocol ExportSink {
    var name: String { get }
    var isConfigured: Bool { get }
    /// Returns true if the batch was durably accepted and can be archived.
    func deliver(_ batch: Outbox.Batch) async -> Result<Void, Error>
}

/// Default sink: leave the file on disk for the share sheet / Files app.
/// Always succeeds — the file *is* the delivery.
struct FileSink: ExportSink {
    let name = "Local files"
    let isConfigured = true

    func deliver(_ batch: Outbox.Batch) async -> Result<Void, Error> {
        .success(())
    }
}

// MARK: - HTTP

struct SinkConfiguration: Codable, Equatable {
    var baseURL: String = ""
    var bearerToken: String = ""
    var enabled: Bool = false

    var endpoint: URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        // Require TLS. This is health data leaving a device; there is no version
        // of this worth doing over plaintext.
        guard components.scheme?.lowercased() == "https" else { return nil }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1/health/batches"
        }
        return components.url
    }

    var isUsable: Bool { enabled && endpoint != nil && !bearerToken.isEmpty }
}

final class HTTPSink: ExportSink {
    let name = "HTTP endpoint"
    private let configuration: SinkConfiguration

    init(configuration: SinkConfiguration) {
        self.configuration = configuration
    }

    var isConfigured: Bool { configuration.isUsable }

    func deliver(_ batch: Outbox.Batch) async -> Result<Void, Error> {
        guard let endpoint = configuration.endpoint, configuration.isUsable else {
            return .failure(SinkError.notConfigured)
        }
        guard let body = try? Data(contentsOf: batch.url) else {
            return .failure(SinkError.unreadableBatch)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        // Derived from the filename, which embeds the batch UUID — so a retry
        // after a network failure that actually succeeded is deduplicated
        // server-side rather than reprocessed. This is the normal case, not an
        // edge case: most retries are of requests that already landed.
        request.setValue(batch.id, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("\(HealthRecord.currentSchemaVersion)", forHTTPHeaderField: "X-Schema-Version")
        request.httpBody = body
        request.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(SinkError.badResponse("Non-HTTP response"))
            }
            switch http.statusCode {
            case 200...299:
                return .success(())
            case 409:
                // Duplicate Idempotency-Key: the server already has this batch.
                // Treat as delivered, otherwise the client retries forever.
                Log.shared.info("sink", "\(batch.displayName) already accepted (409)")
                return .success(())
            case 408, 429, 500...599:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                return .failure(SinkError.retryable(status: http.statusCode,
                                                    retryAfter: retryAfter,
                                                    underlying: nil))
            default:
                // Other 4xx are permanent. Park the batch rather than looping.
                let detail = String(data: data.prefix(512), encoding: .utf8) ?? ""
                return .failure(SinkError.permanent(status: http.statusCode, body: detail))
            }
        } catch {
            return .failure(SinkError.retryable(status: nil, retryAfter: nil, underlying: error))
        }
    }
}

enum SinkError: LocalizedError {
    case notConfigured
    case unreadableBatch
    case badResponse(String)
    case retryable(status: Int?, retryAfter: String?, underlying: Error?)
    case permanent(status: Int, body: String)

    var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "HTTP sink is not configured."
        case .unreadableBatch:
            return "Batch file could not be read."
        case .badResponse(let detail):
            return detail
        case .retryable(let status, let retryAfter, let underlying):
            let code = status.map { "HTTP \($0)" } ?? (underlying?.localizedDescription ?? "network error")
            return retryAfter.map { "\(code), retry after \($0)" } ?? code
        case .permanent(let status, let body):
            return "HTTP \(status) (permanent): \(body)"
        }
    }
}
