import Foundation

/// Where batches go once they're written.
///
/// The uploader sits behind this protocol so v1 could ship as a file exporter
/// and gain an HTTP destination later without touching the read, normalize, or
/// spool layers. `HTTPSink` below implements the contract in
/// docs/ARCHITECTURE.md against the Django server in `server/`.
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
    /// Defaults point at the server deployed by `server/deploy.sh`. They are
    /// only defaults — both fields are editable in Settings, and uploading
    /// stays off until a token is entered and the toggle is flipped.
    static let defaultBaseURL = "https://alena-server.tail03bec9.ts.net"
    /// SHA-256 of that server's certificate. `./deploy.sh pin` prints the
    /// current value; the deploy script never regenerates an existing
    /// certificate, so this changes only if the keypair is deliberately
    /// replaced with `./deploy.sh rotate-cert`.
    static let defaultPin = "a0d5647fcd34c3b465397918534b04c2bc35c986dc166da6a01bd79ccc6e96b2"

    /// Pins this app has shipped before.
    ///
    /// Bumping `defaultPin` alone is not enough: the settings file persists
    /// whatever pin was current when it was written, and a stored value always
    /// wins over a new default. Without this, rotating the certificate would
    /// leave every existing install failing to connect until someone retyped
    /// 64 hex characters by hand on a phone.
    ///
    /// Superseded by the RSA-4096 → ECDSA P-256 rotation: the old certificate
    /// was 1431 bytes, and the tailnet MTU is 1280, so its handshake could not
    /// fit in a single packet and failed on relayed paths.
    static let supersededPins: Set<String> = [
        "819aac937513c6b26e7e150c2ba1acb0dfe84d7a45002d858ad2e0bd93c1212c",
    ]

    var baseURL: String = SinkConfiguration.defaultBaseURL
    var enabled: Bool = false
    /// Empty means "validate normally against system roots", which is what you
    /// want if the endpoint ever gets a publicly trusted certificate.
    var pinnedCertificateSHA256: String = SinkConfiguration.defaultPin

    /// Read straight from the Keychain rather than stored here: this struct is
    /// persisted as plain JSON in Application Support, which is no place for a
    /// credential that grants write access to a health archive.
    ///
    /// Computed, so it is excluded from both the synthesized `Codable` keys and
    /// the synthesized `==` — the token never reaches the settings file.
    var bearerToken: String { Keychain.shared.bearerToken }

    var endpoint: URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        // Require TLS. This is health data leaving a device; there is no version
        // of this worth doing over plaintext. Tailscale already encrypts the
        // link, but that is a property of the network, not of this request —
        // one setting change and the same code would ship health data in clear.
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1/health/batches"
        }
        return components.url
    }

    /// Sibling of `endpoint` used by Test Connection. Derived rather than
    /// separately configured so the two can never point at different servers.
    var pingEndpoint: URL? {
        endpoint?.deletingLastPathComponent().appendingPathComponent("ping")
    }

    /// `/v1/auth/login` and `/v1/auth/logout`, derived from the same base so
    /// credentials can never be sent to a different host than the data.
    private func authEndpoint(_ action: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        components.path = "/v1/auth/\(action)"
        return components.url
    }

    var loginEndpoint: URL? { authEndpoint("login") }
    var logoutEndpoint: URL? { authEndpoint("logout") }

    var statsEndpoint: URL? {
        endpoint?.deletingLastPathComponent().appendingPathComponent("stats")
    }

    /// Any path on the same host, over the same TLS requirement.
    ///
    /// Derived from `baseURL` rather than configured separately so no endpoint
    /// can ever be pointed somewhere the health data is not already going.
    func apiEndpoint(_ path: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        components.path = path
        return components.url
    }

    /// `/v1/analytics/overview` — the daily series behind the phone's charts.
    var overviewEndpoint: URL? { apiEndpoint("/v1/analytics/overview") }

    var isUsable: Bool { enabled && endpoint != nil && !bearerToken.isEmpty }
}

final class HTTPSink: ExportSink {
    let name = "HTTP endpoint"
    private let configuration: SinkConfiguration
    private let session: URLSession

    init(configuration: SinkConfiguration) {
        self.configuration = configuration
        let pinner = CertificatePinner(pins: configuration.pinnedCertificateSHA256)

        // Ephemeral: no on-disk URL cache, no cookie jar. Responses to these
        // requests describe health data, and the default session would persist
        // them outside the protected directories everything else is careful to
        // stay inside.
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 300
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil

        self.session = URLSession(configuration: sessionConfiguration,
                                  delegate: pinner,
                                  delegateQueue: nil)
    }

    deinit {
        // A session holds its delegate until invalidated; without this the
        // pinner leaks once per delivery pass.
        session.finishTasksAndInvalidate()
    }

    var isConfigured: Bool { configuration.isUsable }

    func deliver(_ batch: Outbox.Batch) async -> Result<Void, Error> {
        guard let endpoint = configuration.endpoint, configuration.isUsable else {
            return .failure(SinkError.notConfigured)
        }
        guard FileManager.default.isReadableFile(atPath: batch.url.path) else {
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

        do {
            // Uploaded from the file rather than through `httpBody`. A backfill
            // batch is thousands of records, and reading it into memory to hand
            // it straight to the socket is the kind of thing that gets the app
            // jetsammed mid-sync.
            let (data, response) = try await session.upload(for: request, fromFile: batch.url)
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
            case 401, 403:
                // Surfaced distinctly because the fix is a person pasting a new
                // token, and "HTTP 401 (permanent)" buried in the log is a
                // remarkably easy thing to miss.
                Log.shared.error("sink", "Rejected by server: token invalid or revoked")
                return .failure(SinkError.unauthorized)
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

    /// Exchanges a username and password for a bearer token and stores it in
    /// the Keychain.
    ///
    /// The password is used for exactly this one request and never persisted —
    /// what is kept is the token, which is revocable server-side without
    /// changing the account password.
    func signIn(username: String, password: String, deviceLabel: String) async -> Result<String, Error> {
        guard let endpoint = configuration.loginEndpoint else {
            return .failure(SinkError.notConfigured)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
            "device_label": deviceLabel,
        ])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(SinkError.badResponse("Non-HTTP response"))
            }
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            switch http.statusCode {
            case 200...299:
                guard let token = payload?["token"] as? String, !token.isEmpty else {
                    return .failure(SinkError.badResponse("Server returned no token"))
                }
                Keychain.shared.bearerToken = token
                let user = payload?["username"] as? String ?? username
                return .success("Signed in as \(user)")
            case 401:
                return .failure(SinkError.badResponse("Invalid username or password"))
            case 429:
                let retry = http.value(forHTTPHeaderField: "Retry-After").map { " Try again in \($0)s." } ?? ""
                return .failure(SinkError.badResponse("Too many attempts.\(retry)"))
            default:
                let detail = payload?["detail"] as? String
                    ?? String(data: data.prefix(256), encoding: .utf8)
                    ?? ""
                return .failure(SinkError.permanent(status: http.statusCode, body: detail))
            }
        } catch {
            return .failure(error)
        }
    }

    /// Revokes this device's token server-side, then forgets it locally.
    ///
    /// Clearing only the local copy would leave a credential that still works
    /// for anyone who has it.
    func signOut() async -> Result<Void, Error> {
        defer { Keychain.shared.bearerToken = "" }

        guard let endpoint = configuration.logoutEndpoint,
              !configuration.bearerToken.isEmpty else {
            return .success(())
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            _ = try await session.data(for: request)
            return .success(())
        } catch {
            // The local token is cleared regardless — a network failure must
            // not leave the phone signed in.
            return .failure(error)
        }
    }

    /// Asks the server what it is holding.
    ///
    /// `fresh` bypasses the server's short cache, which is what a deliberate
    /// pull-to-refresh should do; the cached path is fine for merely opening
    /// the screen.
    func fetchStatus(fresh: Bool = false) async -> Result<ServerStatus, Error> {
        guard let base = configuration.statsEndpoint else {
            return .failure(SinkError.notConfigured)
        }
        guard !configuration.bearerToken.isEmpty else {
            return .failure(SinkError.notConfigured)
        }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        if fresh { components?.queryItems = [URLQueryItem(name: "fresh", value: "1")] }
        guard let url = components?.url else { return .failure(SinkError.notConfigured) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(SinkError.badResponse("Non-HTTP response"))
            }
            switch http.statusCode {
            case 200...299:
                do {
                    return .success(try JSONDecoder().decode(ServerStatus.self, from: data))
                } catch {
                    return .failure(SinkError.badResponse("Could not read server response: \(error)"))
                }
            case 401, 403:
                return .failure(SinkError.unauthorized)
            default:
                let detail = String(data: data.prefix(256), encoding: .utf8) ?? ""
                return .failure(SinkError.permanent(status: http.statusCode, body: detail))
            }
        } catch {
            return .failure(error)
        }
    }

    /// Daily series for the phone's trend charts, for the last `days` days.
    func fetchOverview(days: Int = 30) async -> Result<AnalyticsOverview, Error> {
        guard let base = configuration.overviewEndpoint, !configuration.bearerToken.isEmpty else {
            return .failure(SinkError.notConfigured)
        }
        let today = Date()
        let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "from", value: formatter.string(from: from)),
            URLQueryItem(name: "to", value: formatter.string(from: today)),
        ]
        guard let url = components?.url else { return .failure(SinkError.notConfigured) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(SinkError.badResponse("Non-HTTP response"))
            }
            switch http.statusCode {
            case 200...299:
                do {
                    return .success(try JSONDecoder().decode(AnalyticsOverview.self, from: data))
                } catch {
                    return .failure(SinkError.badResponse("Could not read trends: \(error)"))
                }
            case 401, 403:
                return .failure(SinkError.unauthorized)
            default:
                return .failure(SinkError.permanent(status: http.statusCode, body: ""))
            }
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Insights

    /// Shared plumbing for the analysis endpoints: bearer auth, the pinned
    /// session, and the same status-code contract as everything else.
    private func fetch<T: Decodable>(
        _ url: URL?,
        as type: T.Type,
        timeout: TimeInterval = 30,
        method: String = "GET",
        body: Data? = nil
    ) async -> Result<T, Error> {
        guard let url, !configuration.bearerToken.isEmpty else {
            return .failure(SinkError.notConfigured)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(SinkError.badResponse("Non-HTTP response"))
            }
            switch http.statusCode {
            case 200...299:
                do {
                    return .success(try JSONDecoder().decode(T.self, from: data))
                } catch {
                    return .failure(SinkError.badResponse("Could not read the response: \(error)"))
                }
            case 401, 403:
                return .failure(SinkError.unauthorized)
            case 429:
                let retry = http.value(forHTTPHeaderField: "Retry-After").map { " Try again in \($0)s." } ?? ""
                return .failure(SinkError.badResponse("The server is busy.\(retry)"))
            default:
                let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return .failure(SinkError.permanent(
                    status: http.statusCode,
                    body: detail?["detail"] as? String ?? ""
                ))
            }
        } catch {
            return .failure(error)
        }
    }

    /// The deterministic snapshot: every headline metric against its own
    /// baseline. No model runs behind this, so it is fast and always available.
    func fetchSnapshot() async -> Result<HealthSnapshot, Error> {
        await fetch(configuration.apiEndpoint("/v1/analysis/snapshot"), as: HealthSnapshot.self)
    }

    func fetchInsightStatus() async -> Result<InsightStatus, Error> {
        await fetch(configuration.apiEndpoint("/v1/insights/status"), as: InsightStatus.self, timeout: 15)
    }

    /// Asks a question about the data already on the server.
    ///
    /// The long timeout is not slack: a local model works through a tool loop
    /// and a structured answer in tens of seconds, and a timeout that fires
    /// mid-answer is indistinguishable from a broken server.
    func ask(question: String, context: String, remember: Bool) async -> Result<InsightResult, Error> {
        let body = try? JSONSerialization.data(withJSONObject: [
            "question": question,
            "context": context,
            "remember": remember,
            "tz": TimeZone.current.identifier,
        ])
        return await fetch(
            configuration.apiEndpoint("/v1/insights/ask"),
            as: InsightResult.self,
            timeout: 240,
            method: "POST",
            body: body ?? Data("{}".utf8)
        )
    }

    func weeklyReview() async -> Result<InsightResult, Error> {
        let body = try? JSONSerialization.data(withJSONObject: ["tz": TimeZone.current.identifier])
        return await fetch(
            configuration.apiEndpoint("/v1/insights/weekly"),
            as: InsightResult.self,
            timeout: 240,
            method: "POST",
            body: body ?? Data("{}".utf8)
        )
    }

    /// Checks URL, TLS pin, and token in one round trip, without shipping any
    /// health data. Background sync fails silently by default — this is the one
    /// place the configuration can be proven wrong while someone is watching.
    func probe() async -> Result<String, Error> {
        guard let endpoint = configuration.pingEndpoint else {
            return .failure(SinkError.notConfigured)
        }
        guard !configuration.bearerToken.isEmpty else {
            return .failure(SinkError.notConfigured)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(SinkError.badResponse("Non-HTTP response"))
            }
            switch http.statusCode {
            case 200...299:
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let label = payload?["token"] as? String ?? "unnamed"
                return .success("Connected. Token: \(label)")
            case 401, 403:
                return .failure(SinkError.unauthorized)
            default:
                let detail = String(data: data.prefix(256), encoding: .utf8) ?? ""
                return .failure(SinkError.permanent(status: http.statusCode, body: detail))
            }
        } catch {
            return .failure(error)
        }
    }
}

enum SinkError: LocalizedError {
    case notConfigured
    case unreadableBatch
    case badResponse(String)
    case unauthorized
    case retryable(status: Int?, retryAfter: String?, underlying: Error?)
    case permanent(status: Int, body: String)

    var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Needs an https:// URL and a bearer token."
        case .unreadableBatch:
            return "Batch file could not be read."
        case .badResponse(let detail):
            return detail
        case .unauthorized:
            return "Server rejected the token. Issue a new one with ./deploy.sh token."
        case .retryable(let status, let retryAfter, let underlying):
            let code = status.map { "HTTP \($0)" } ?? (underlying?.localizedDescription ?? "network error")
            return retryAfter.map { "\(code), retry after \($0)" } ?? code
        case .permanent(let status, let body):
            return "HTTP \(status) (permanent): \(body)"
        }
    }
}
