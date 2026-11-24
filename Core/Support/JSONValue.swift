import Foundation

/// Untyped JSON used at protocol boundaries (JSON-RPC, LSP).
nonisolated public enum JSONValue: Codable, Sendable, Equatable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])

	public init(from decoder: Decoder) throws {
		let c = try decoder.singleValueContainer()
		if c.decodeNil() { self = .null }
		else if let v = try? c.decode(Bool.self) { self = .bool(v) }
		else if let v = try? c.decode(Double.self) { self = .number(v) }
		else if let v = try? c.decode(String.self) { self = .string(v) }
		else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
		else { self = .object(try c.decode([String: JSONValue].self)) }
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.singleValueContainer()
		switch self {
		case .null: try c.encodeNil()
		case .bool(let v): try c.encode(v)
		case .number(let v): try c.encode(v)
		case .string(let v): try c.encode(v)
		case .array(let v): try c.encode(v)
		case .object(let v): try c.encode(v)
		}
	}

	public subscript(key: String) -> JSONValue? {
		if case .object(let o) = self { return o[key] }
		return nil
	}

	public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
	public var doubleValue: Double? { if case .number(let n) = self { n } else { nil } }
	public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
}

nonisolated extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
	ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
	public init(stringLiteral v: String) { self = .string(v) }
	public init(dictionaryLiteral elements: (String, JSONValue)...) {
		self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
	}
	public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
	public init(integerLiteral v: Int) { self = .number(Double(v)) }
	public init(booleanLiteral v: Bool) { self = .bool(v) }
	public init(nilLiteral: ()) { self = .null }
}
