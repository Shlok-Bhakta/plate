// A lossless JSON value plus the lenient reading and writing helpers every synced row uses.
// Rows keep fields the app doesn't know about in `extra`, so editing a row on the phone never
// strips something the server or the agent wrote.
import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Any Encodable value as JSON (used to put typed rows into mutations).
    init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

struct AnyKey: CodingKey, Hashable {
    var stringValue: String
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

/// Lenient field access: a wrong type or a missing key reads as nil instead of failing the row.
struct RowReader {
    let c: KeyedDecodingContainer<AnyKey>
    init(_ decoder: Decoder) throws { c = try decoder.container(keyedBy: AnyKey.self) }

    func has(_ k: String) -> Bool { c.contains(AnyKey(k)) }
    func string(_ k: String) -> String? { (try? c.decodeIfPresent(String.self, forKey: AnyKey(k))) ?? nil }
    func bool(_ k: String) -> Bool? {
        if let b = (try? c.decodeIfPresent(Bool.self, forKey: AnyKey(k))) ?? nil { return b }
        return double(k).map { $0 != 0 }
    }
    func double(_ k: String) -> Double? {
        guard let v = (try? c.decodeIfPresent(Double.self, forKey: AnyKey(k))) ?? nil, v.isFinite else { return nil }
        return v
    }
    /// Out-of-range numbers (|x| ≥ 2^63 would trap in `Int(_:)`) read as unknown.
    func int(_ k: String) -> Int? { double(k).flatMap { abs($0) < 9e18 ? Int($0) : nil } }
    func value<T: Decodable>(_ k: String, as type: T.Type = T.self) -> T? {
        (try? c.decodeIfPresent(T.self, forKey: AnyKey(k))) ?? nil
    }
    /// `{key: number}`; non-numbers and negatives are dropped, so unknown stays unknown.
    func nutrients(_ k: String) -> NutrientMap {
        guard let raw = value(k, as: [String: JSONValue].self) else { return [:] }
        var out = NutrientMap()
        for (key, v) in raw { if let n = v.double, n.isFinite, n >= 0 { out[key] = n } }
        return out
    }
    func numberMap(_ k: String) -> [String: Double] { nutrients(k) }
    func extras(known: Set<String>) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in c.allKeys where !known.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) { out[key.stringValue] = v }
        }
        return out
    }
}

struct RowWriter {
    var c: KeyedEncodingContainer<AnyKey>
    init(_ encoder: Encoder) { c = encoder.container(keyedBy: AnyKey.self) }

    mutating func put<T: Encodable>(_ k: String, _ v: T?) throws {
        if let v { try c.encode(v, forKey: AnyKey(k)) }
    }
    /// Writes JSON null for nil (for fields the spec lists as nullable).
    mutating func putOrNull<T: Encodable>(_ k: String, _ v: T?) throws {
        if let v { try c.encode(v, forKey: AnyKey(k)) } else { try c.encodeNil(forKey: AnyKey(k)) }
    }
    mutating func extras(_ extra: [String: JSONValue], known: Set<String>) throws {
        for (k, v) in extra where !known.contains(k) { try c.encode(v, forKey: AnyKey(k)) }
    }
}

extension Int {
    /// `Int(x)` that can't trap: NaN is 0 and out-of-range values clamp to `Int.min ... Int.max`.
    init(saturating x: Double) {
        if x.isNaN { self = 0 }
        else if x >= 9_223_372_036_854_775_808.0 { self = .max }
        else if x < -9_223_372_036_854_775_808.0 { self = .min }
        else { self = Int(x) }
    }
}
