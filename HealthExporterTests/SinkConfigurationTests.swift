import XCTest
@testable import HealthExporter

/// URL construction, which is where this app's quietest bugs have lived.
///
/// Both traps below shipped. The query-string one produced a 404 that looked
/// like a missing route on the server, and the https requirement is the only
/// thing standing between a mistyped setting and health data in clear text.
final class SinkConfigurationTests: XCTestCase {

    private func configuration(_ base: String) -> SinkConfiguration {
        var configuration = SinkConfiguration()
        configuration.baseURL = base
        return configuration
    }

    // MARK: - Transport

    func testPlaintextIsRefused() {
        // Not a preference. Tailscale encrypts the link, but that is a property
        // of the network rather than of this request.
        XCTAssertNil(configuration("http://example.com").endpoint)
        XCTAssertNil(configuration("http://example.com").loginEndpoint)
        XCTAssertNil(configuration("http://example.com").apiEndpoint("/v1/chat/sessions"))
    }

    func testSchemeComparisonIsCaseInsensitive() {
        XCTAssertNotNil(configuration("HTTPS://example.com").endpoint)
    }

    func testGarbageBaseURLYieldsNoEndpointRatherThanCrashing() {
        XCTAssertNil(configuration("").endpoint)
        XCTAssertNil(configuration("not a url at all").endpoint)
        XCTAssertNil(configuration("https://").endpoint)
    }

    // MARK: - Paths

    func testBareHostGetsTheIngestPath() {
        XCTAssertEqual(
            configuration("https://example.com").endpoint?.absoluteString,
            "https://example.com/v1/health/batches"
        )
        // A trailing slash is the same thing typed differently.
        XCTAssertEqual(
            configuration("https://example.com/").endpoint?.absoluteString,
            "https://example.com/v1/health/batches"
        )
    }

    func testAnExplicitPathIsNowAPrefix() {
        // Deliberately changed. A non-empty path used to *be* the batches
        // endpoint, with the siblings derived by deleting its last component —
        // which only ever worked at the root. It is a mount prefix now, and
        // every route hangs off it.
        XCTAssertEqual(
            configuration("https://example.com/ingest").endpoint?.absoluteString,
            "https://example.com/ingest/v1/health/batches"
        )
    }

    func testSiblingEndpointsShareTheEndpointsHost() {
        // Derived rather than separately configured, so credentials can never be
        // sent to a different host than the health data.
        let sink = configuration("https://example.com")
        XCTAssertEqual(sink.pingEndpoint?.absoluteString, "https://example.com/v1/health/ping")
        XCTAssertEqual(sink.statsEndpoint?.absoluteString, "https://example.com/v1/health/stats")
        XCTAssertEqual(sink.coverageEndpoint?.absoluteString, "https://example.com/v1/health/coverage")
        XCTAssertEqual(sink.loginEndpoint?.absoluteString, "https://example.com/v1/auth/login")
        XCTAssertEqual(sink.logoutEndpoint?.absoluteString, "https://example.com/v1/auth/logout")
    }

    // MARK: - A server mounted under a path

    func testEveryEndpointKeepsTheBasePath() {
        // The bug this section exists for. `apiEndpoint` assigned
        // `components.path` outright, so a prefix was silently dropped from
        // every call — and `pingEndpoint`, built by deleting the last path
        // component of the batches URL, resolved to a bare "/ping".
        let sink = configuration("https://example.com/health-app")

        XCTAssertEqual(sink.endpoint?.path, "/health-app/v1/health/batches")
        XCTAssertEqual(sink.pingEndpoint?.path, "/health-app/v1/health/ping")
        XCTAssertEqual(sink.statsEndpoint?.path, "/health-app/v1/health/stats")
        XCTAssertEqual(sink.coverageEndpoint?.path, "/health-app/v1/health/coverage")
        XCTAssertEqual(sink.loginEndpoint?.path, "/health-app/v1/auth/login")
        XCTAssertEqual(sink.logoutEndpoint?.path, "/health-app/v1/auth/logout")
        XCTAssertEqual(sink.overviewEndpoint?.path, "/health-app/v1/analytics/overview")
        XCTAssertEqual(
            sink.apiEndpoint("/v1/analysis/snapshot")?.path,
            "/health-app/v1/analysis/snapshot"
        )
    }

    func testABasePathSurvivesAQueryString() {
        let url = configuration("https://example.com/health-app")
            .apiEndpoint("/v1/chat/sessions", query: [URLQueryItem(name: "limit", value: "40")])
        XCTAssertEqual(url?.absoluteString, "https://example.com/health-app/v1/chat/sessions?limit=40")
    }

    func testATrailingSlashOnTheBaseDoesNotDoubleUp() {
        let sink = configuration("https://example.com/health-app/")
        XCTAssertEqual(sink.endpoint?.path, "/health-app/v1/health/batches")
    }

    func testANestedBasePathIsKept() {
        let sink = configuration("https://example.com/apps/health")
        XCTAssertEqual(sink.endpoint?.path, "/apps/health/v1/health/batches")
    }

    func testTheRootCaseIsUnchanged() {
        // Every existing install has no path, and must be completely unaffected.
        let sink = configuration("https://example.com")
        XCTAssertEqual(sink.endpoint?.absoluteString, "https://example.com/v1/health/batches")
        XCTAssertEqual(sink.pingEndpoint?.absoluteString, "https://example.com/v1/health/ping")
    }

    // MARK: - Query strings

    func testQueryItemsAreNotPercentEncodedIntoThePath() {
        // The shipped bug: `URLComponents.path` escapes everything illegal in a
        // path, `?` included, so passing "/v1/chat/sessions?limit=40" as one
        // string produced `/v1/chat/sessions%3Flimit=40` — one long path
        // matching no route, answered 404. Every endpoint before the chat list
        // was query-free, so nothing had ever stepped on it.
        let url = configuration("https://example.com")
            .apiEndpoint("/v1/chat/sessions", query: [URLQueryItem(name: "limit", value: "40")])

        XCTAssertEqual(url?.absoluteString, "https://example.com/v1/chat/sessions?limit=40")
        XCTAssertEqual(url?.path, "/v1/chat/sessions")
    }

    func testAnEmptyQueryLeavesNoTrailingQuestionMark() {
        let url = configuration("https://example.com").apiEndpoint("/v1/chat/sessions", query: [])
        XCTAssertEqual(url?.absoluteString, "https://example.com/v1/chat/sessions")
    }

    // MARK: - Credentials

    func testTheTokenNeverReachesTheSettingsFile() throws {
        // `bearerToken` is computed off the Keychain precisely so it is excluded
        // from the synthesized CodingKeys. This struct is persisted as plain
        // JSON in Application Support.
        let encoded = try JSONEncoder().encode(configuration("https://example.com"))
        let json = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(json.contains("bearerToken"))
        XCTAssertFalse(json.contains("token"))
    }

    func testASupersededPinIsRecognised() {
        // An install carrying a retired pin has to clear it rather than fail
        // every upload against a certificate that is now perfectly valid.
        for pin in SinkConfiguration.supersededPins {
            XCTAssertEqual(pin.count, 64, "a SHA-256 pin is 64 hex characters")
        }
        XCTAssertFalse(SinkConfiguration.supersededPins.contains(SinkConfiguration.defaultPin))
    }
}
