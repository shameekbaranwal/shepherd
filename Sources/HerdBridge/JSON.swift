import Foundation

/// Minimal Sendable JSON value used for request parameters, so params can
/// cross actor boundaries under strict concurrency without `[String: Any]`.
public enum JSON: Sendable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// Bridge to Foundation types for JSONSerialization.
    var any: Any {
        switch self {
        case .object(let o): return o.mapValues { $0.any }
        case .array(let a): return a.map { $0.any }
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}

extension JSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
extension JSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
}
extension JSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
