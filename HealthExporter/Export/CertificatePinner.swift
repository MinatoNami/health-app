import CryptoKit
import Foundation

/// Trusts exactly one certificate, by SHA-256 of its DER encoding.
///
/// The destination is a private server on a Tailscale tailnet. A tailnet name
/// cannot get a publicly-trusted certificate unless HTTPS certificates are
/// enabled for the tailnet, and installing a custom CA profile on the phone
/// would make the device trust that CA for *every* site it visits. Pinning one
/// certificate is both narrower and stronger than either: the connection
/// succeeds only against this exact server, and a compromised public CA cannot
/// forge it.
///
/// Because trust is decided here rather than by the system, the usual
/// certificate-lifetime rules do not apply — the pin is the whole check, so the
/// server certificate is long-lived deliberately and expiry cannot silently
/// break sync. What matters instead is that the pin is right: if it stops
/// matching, the upload fails closed rather than falling back to system trust.
///
/// With no pin configured this defers to normal system validation, so pointing
/// the app at a server with a real certificate needs no code change.
final class CertificatePinner: NSObject, URLSessionDelegate {

    /// Lowercase hex digests. Multiple pins are accepted so a certificate can
    /// be rotated by publishing the new pin before the switch, rather than
    /// requiring the phone and server to change in the same instant.
    private let pins: Set<String>

    init(pins: String) {
        self.pins = Set(
            pins.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
                .map { CertificatePinner.normalize(String($0)) }
                .filter { $0.count == 64 }
        )
    }

    var isEnabled: Bool { !pins.isEmpty }

    /// Accepts the shapes people actually paste: `AB:CD:…`, `ab cd …`, or the
    /// bare hex openssl prints.
    static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isHexDigit }
    }

    static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // No pin means the operator is relying on a publicly trusted
        // certificate. Handing back .useCredential here would disable
        // validation entirely, which is the classic way this code goes wrong.
        guard isEnabled else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            Log.shared.error("pinning", "Server presented no certificate chain")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let presented = CertificatePinner.fingerprint(of: leaf)
        if pins.contains(presented) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            // Deliberately logged in full: the recovery action is to compare
            // this against `./deploy.sh pin` and paste the right value in.
            Log.shared.error("pinning",
                "Certificate mismatch — server presented \(presented), expected \(pins.joined(separator: " or "))")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
