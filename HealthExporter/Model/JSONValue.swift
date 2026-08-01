import Foundation

/// A JSON-safe value. HealthKit metadata is `[String: Any]`, which is not
/// `Codable`, so every metadata dictionary is funnelled through this type
/// before it reaches the encoder.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d.isFinite ? d : 0)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
}

extension JSONValue {
    /// Best-effort conversion of an arbitrary Objective-C value into JSON.
    /// Never throws and never returns `nil` — unknown types degrade to their
    /// string description rather than being silently dropped, so nothing in
    /// HealthKit metadata disappears without a trace.
    static func from(_ any: Any) -> JSONValue {
        switch any {
        case let v as JSONValue:
            return v
        case let v as String:
            return .string(v)
        case let v as NSNumber:
            // NSNumber boxes Bool as well as numerics; distinguish by CFTypeID.
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            return .number(v.doubleValue)
        case let v as Date:
            return .string(Timestamps.iso8601(v))
        case let v as [Any]:
            return .array(v.map { JSONValue.from($0) })
        case let v as [String: Any]:
            return .object(v.mapValues { JSONValue.from($0) })
        case is NSNull:
            return .null
        default:
            return .string(String(describing: any))
        }
    }

    /// Builds an object from a dictionary that may contain nils, dropping them.
    /// Named distinctly from the `object` case to avoid overload ambiguity.
    static func compacting(_ pairs: [String: JSONValue?]) -> JSONValue {
        .object(pairs.compactMapValues { $0 })
    }
}
