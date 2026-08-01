import Foundation
import HealthKit

enum Timestamps {
    /// Formatters are expensive to build and not cheap to reuse across threads,
    /// so keep one per zone behind a lock. Sync is chatty enough that building
    /// a formatter per sample shows up in profiles.
    private static let lock = NSLock()
    private static var cache: [String: ISO8601DateFormatter] = [:]

    private static func formatter(for timeZone: TimeZone) -> ISO8601DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[timeZone.identifier] { return existing }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        cache[timeZone.identifier] = f
        return f
    }

    /// ISO 8601 with an explicit UTC offset, e.g. `2026-07-31T08:14:02+08:00`.
    static func iso8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(for: timeZone).string(from: date)
    }

    static func parse(_ string: String) -> Date? {
        formatter(for: TimeZone(secondsFromGMT: 0) ?? .current).date(from: string)
    }

    /// `HKMetadataKeyTimeZone` holds an IANA name when the sample carries one.
    /// Prefer it over the device's current zone: it tells you where the user
    /// actually was, which is what makes travel-spanning day boundaries right.
    static func timeZone(fromMetadata metadata: [String: Any]?) -> TimeZone? {
        guard let name = metadata?[HKMetadataKeyTimeZone] as? String else { return nil }
        return TimeZone(identifier: name)
    }
}

extension String {
    /// `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` -> `heart_rate_variability_sdnn`
    var healthKitSlug: String {
        var s = self
        for prefix in [
            "HKQuantityTypeIdentifier",
            "HKCategoryTypeIdentifier",
            "HKCharacteristicTypeIdentifier",
            "HKCorrelationTypeIdentifier",
            "HKDataTypeIdentifier"
        ] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        guard !s.isEmpty else { return self.lowercased() }

        var out = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            if ch.isUppercase {
                let prevIsLower = i > 0 && chars[i - 1].isLowercase
                let prevIsDigit = i > 0 && chars[i - 1].isNumber
                // Break before an uppercase run that ends a word: the "R" in
                // "HRVSDNNRate" style boundaries. Keeps acronyms intact.
                let startsNewWord = i > 0 && i + 1 < chars.count
                    && chars[i - 1].isUppercase && chars[i + 1].isLowercase
                if prevIsLower || prevIsDigit || startsNewWord { out.append("_") }
                out.append(Character(ch.lowercased()))
            } else if ch.isNumber {
                let prevIsLetter = i > 0 && chars[i - 1].isLetter
                if prevIsLetter && !(i > 0 && chars[i - 1].isUppercase) { out.append("_") }
                out.append(ch)
            } else {
                out.append(Character(ch.lowercased()))
            }
        }
        return out
    }
}
