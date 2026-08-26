import XCTest
@testable import HealthExporter

/// Django emits six fractional digits. `ISO8601DateFormatter` is dependable for
/// three, and it returns `nil` rather than throwing — so the failure surfaced as
/// a decode error on whatever field happened to be next, which is a long way
/// from the actual cause.
final class ServerDateTests: XCTestCase {

    private func components(_ date: Date) -> DateComponents {
        Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: date
        )
    }

    func testSixFractionalDigitsParse() throws {
        let date = try XCTUnwrap(ServerDate.parse("2026-08-23T03:17:21.241736+00:00"))
        let parts = components(date)

        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 8)
        XCTAssertEqual(parts.day, 23)
        XCTAssertEqual(parts.hour, 3)
        XCTAssertEqual(parts.minute, 17)
        XCTAssertEqual(parts.second, 21)
    }

    func testThreeFractionalDigitsParse() {
        XCTAssertNotNil(ServerDate.parse("2026-08-23T03:17:21.241+00:00"))
    }

    func testNoFractionalDigitsParse() {
        XCTAssertNotNil(ServerDate.parse("2026-08-23T03:17:21+00:00"))
        XCTAssertNotNil(ServerDate.parse("2026-08-23T03:17:21Z"))
    }

    func testZuluAndOffsetAgreeOnTheSameInstant() {
        let zulu = ServerDate.parse("2026-08-23T03:17:21.241736Z")
        let offset = ServerDate.parse("2026-08-23T11:17:21.241736+08:00")
        XCTAssertEqual(zulu, offset)
    }

    func testANegativeOffsetIsNotMistakenForTheFractionSeparator() {
        // The fallback strips the fractional part by finding the next "+", "Z"
        // or "-" after the dot. A western offset makes that "-" the terminator,
        // which is the one case where the scan could cut in the wrong place.
        let west = ServerDate.parse("2026-08-22T23:17:21.241736-04:00")
        let zulu = ServerDate.parse("2026-08-23T03:17:21.241736Z")
        XCTAssertEqual(west, zulu)
    }

    func testNonsenseReturnsNil() {
        XCTAssertNil(ServerDate.parse(""))
        XCTAssertNil(ServerDate.parse("yesterday"))
        XCTAssertNil(ServerDate.parse("2026-13-45T99:99:99Z"))
    }

    func testOneBadTimestampDoesNotFailTheWholeResponse() throws {
        // A conversation list is still worth showing with one odd timestamp in
        // it, so the strategy substitutes rather than throwing.
        struct Row: Codable { let createdAt: Date }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ServerDate.decodingStrategy

        let good = try decoder.decode(
            Row.self, from: Data(#"{"createdAt":"2026-08-23T03:17:21.241736+00:00"}"#.utf8)
        )
        let bad = try decoder.decode(Row.self, from: Data(#"{"createdAt":"nonsense"}"#.utf8))

        XCTAssertGreaterThan(good.createdAt, Date.distantPast)
        XCTAssertEqual(bad.createdAt, .distantPast)
    }
}
