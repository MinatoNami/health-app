import XCTest
@testable import HealthExporter

/// The rule behind the "isn't syncing" alert.
///
/// Worth testing rather than eyeballing because both halves of it are easy to
/// get wrong in opposite directions: too eager and the alert gets switched off
/// before the day it matters, too shy and it never fires at all — which is the
/// state the app was already in.
@MainActor
final class SyncFailureNotifierTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Uploading configured and working: the baseline every case varies from.
    private func healthy(
        uploadEnabled: Bool = true,
        serverUsable: Bool = true,
        isSignedIn: Bool = true,
        tokenRejected: Bool = false,
        pendingBatches: Int = 0,
        daysSinceProgress: Double = 0
    ) -> SyncFailureNotifier.Conditions {
        SyncFailureNotifier.Conditions(
            uploadEnabled: uploadEnabled,
            serverUsable: serverUsable,
            isSignedIn: isSignedIn,
            tokenRejected: tokenRejected,
            pendingBatches: pendingBatches,
            lastProgressAt: now.addingTimeInterval(-daysSinceProgress * 86_400)
        )
    }

    private func fault(_ conditions: SyncFailureNotifier.Conditions) -> SyncFailureNotifier.Fault? {
        SyncFailureNotifier.fault(for: conditions, now: now)
    }

    // MARK: - Silence where silence is right

    func testNothingIsWrongWhenTheQueueIsEmpty() {
        XCTAssertNil(fault(healthy(daysSinceProgress: 90)))
    }

    func testAChoiceNotToUploadIsNotAFault() {
        // Alerting about a deliberate setting is how an alert gets muted.
        XCTAssertNil(fault(healthy(uploadEnabled: false, pendingBatches: 40, daysSinceProgress: 30)))
        XCTAssertNil(fault(healthy(serverUsable: false, pendingBatches: 40, daysSinceProgress: 30)))
        XCTAssertNil(fault(healthy(isSignedIn: false, pendingBatches: 40, daysSinceProgress: 30)))
    }

    func testASignedOutPhoneIsSilentEvenWithARejectedToken() {
        // Signing out revokes server-side and clears the token. Whatever the
        // last delivery attempt said, there is nothing to warn about.
        XCTAssertNil(fault(healthy(isSignedIn: false, tokenRejected: true, pendingBatches: 5)))
    }

    func testAWeekendOffWifiDoesNotTripIt() {
        // Two days queued is an ordinary gap: a trip, Low Power Mode, no
        // network. The window is deliberately longer than that.
        XCTAssertNil(fault(healthy(pendingBatches: 12, daysSinceProgress: 2)))
    }

    func testTheBoundaryItselfIsNotYetAFault() {
        XCTAssertNil(fault(healthy(pendingBatches: 12, daysSinceProgress: 3)))
    }

    func testNoClockToMeasureAgainstStaysQuiet() {
        var conditions = healthy(pendingBatches: 12)
        conditions.lastProgressAt = nil
        XCTAssertNil(fault(conditions))
    }

    // MARK: - Speech where speech is right

    func testAStalledQueueEventuallySpeaks() {
        XCTAssertEqual(fault(healthy(pendingBatches: 12, daysSinceProgress: 4)), .stalled)
        XCTAssertEqual(fault(healthy(pendingBatches: 1, daysSinceProgress: 35)), .stalled)
    }

    func testARejectedTokenDoesNotWaitOutTheStallWindow() {
        // Nothing will upload again until somebody signs in, so waiting three
        // days to mention it helps nobody.
        XCTAssertEqual(
            fault(healthy(tokenRejected: true, pendingBatches: 0, daysSinceProgress: 0)),
            .tokenRejected
        )
    }

    func testARejectedTokenOutranksAStall() {
        // Both are true after a revocation; only one says what to do about it.
        XCTAssertEqual(
            fault(healthy(tokenRejected: true, pendingBatches: 80, daysSinceProgress: 20)),
            .tokenRejected
        )
    }

    // MARK: - What it says

    func testEachFaultSaysWhatToDo() {
        XCTAssertTrue(SyncFailureNotifier.Fault.tokenRejected.body.contains("sign in again"))
        XCTAssertFalse(SyncFailureNotifier.Fault.stalled.body.isEmpty)
    }
}
