import Foundation

/// Stops a delivery run from grinding through the whole queue against a server
/// it cannot reach.
///
/// Every batch gets four attempts with backoff, and each attempt can wait out a
/// 60-second request timeout — a host that is down on the tailnet tends to hang
/// rather than refuse. Against an unreachable server that was roughly four
/// minutes per batch, for every batch: a few hundred queued meant every
/// background task expired mid-run, and `isSyncing` held the rest of the app off
/// the whole time.
///
/// Three states, the usual shape for this:
///
/// - **Closed.** Normal: up to `attemptsPerBatch` tries each.
/// - **Open.** `tripAfter` batches in a row used up every attempt without the
///   server taking them. The run stops there; the batches stay queued.
/// - **Probing.** Every run after that starts with a single attempt at a single
///   batch. If it lands, the breaker closes and the run carries on as normal; if
///   not, the run stops after one request instead of four minutes per batch.
///
/// Kept in memory, deliberately. A relaunch starts closed, so the first run of
/// a fresh launch gets the full patience — cheap insurance against a state that
/// was right an hour ago being wrong now.
///
/// Separate from the authentication breaker in `deliverPending`, which trips on
/// a different signal and is fixed by a different person: a 401 needs someone
/// to sign in again; an unreachable server mostly needs time.
struct UploadBreaker {
    static let attemptsPerBatch = 4
    static let tripAfter = 2

    private(set) var isOpen = false
    private var consecutiveExhausted = 0

    /// How many tries the next batch gets.
    var attemptsForNextBatch: Int { isOpen ? 1 : Self.attemptsPerBatch }

    /// The server took a batch: whatever was wrong is not wrong now.
    mutating func recordDelivered() {
        isOpen = false
        consecutiveExhausted = 0
    }

    /// The server answered, but about this batch rather than about itself — a
    /// rejection, a parked batch. Proof it is reachable, so the count resets,
    /// but no reason to close an open breaker on its own.
    mutating func recordAnswered() {
        consecutiveExhausted = 0
    }

    /// A batch used every attempt it was given on retryable failures. Returns
    /// true when the run should stop.
    mutating func recordExhausted() -> Bool {
        consecutiveExhausted += 1
        if isOpen || consecutiveExhausted >= Self.tripAfter {
            isOpen = true
            return true
        }
        return false
    }

    /// Delay before the next retry of the same batch. Exponential with jitter,
    /// unless the server said how long to wait — then that, within reason.
    static func backoff(attempt: Int, retryAfter: String?,
                        jitter: Double = Double.random(in: 0...0.5)) -> TimeInterval {
        let cap: TimeInterval = 60
        if let retryAfter, let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)),
           seconds >= 0 {
            return min(seconds, cap)
        }
        return min(2 * pow(2, Double(attempt - 1)) + jitter, cap)
    }
}
