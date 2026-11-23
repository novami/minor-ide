import Foundation

/// A JSON value that keeps object key order and the line of each value (the validator reports lines).
public indirect enum JSONTree: Sendable, Equatable {
	case object([Member])
	case array([JSONTree])
	case string(String)
	case number(Double)
	case bool(Bool)
	case null

	public struct Member: Sendable, Equatable {
		public var key: String
		public var value: JSONTree
		public var line: Int
	}

	public subscript(key: String) -> JSONTree? {
		guard case .object(let members) = self else { return nil }
		return members.last { $0.key == key }?.value
	}

	public var string: String? {
		if case .string(let s) = self { return s }
		return nil
	}
}

public struct JSONTreeError: Error, CustomStringConvertible {
	public var line: Int
	public var message: String
	public var description: String { "line \(line): \(message)" }
}

/// A small JSON parser. Unlike JSONSerialization it reports duplicate keys (with their dotted path).
public struct JSONTreeParser {
	public private(set) var duplicates: [(path: String, line: Int)] = []
	private let bytes: [UInt8]
	private var at = 0
	private var line = 1
	private var depth = 0

	public static func parse(_ data: Data) throws(JSONTreeError) -> (tree: JSONTree, duplicates: [(path: String, line: Int)]) {
		var parser = JSONTreeParser(bytes: [UInt8](data))
		parser.skipSpace()
		let tree = try parser.value(path: "")
		parser.skipSpace()
		guard parser.at == parser.bytes.count else { throw parser.error("unexpected text after the end") }
		return (tree, parser.duplicates)
	}

	private init(bytes: [UInt8]) {
		// Skip a UTF-8 byte order mark.
		self.bytes = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes
	}

	private func error(_ message: String) -> JSONTreeError { JSONTreeError(line: line, message: message) }

	private mutating func skipSpace() {
		while at < bytes.count {
			switch bytes[at] {
			case 0x0A: line += 1; at += 1
			case 0x20, 0x09, 0x0D: at += 1
			default: return
			}
		}
	}

	private mutating func value(path: String) throws(JSONTreeError) -> JSONTree {
		guard at < bytes.count else { throw error("unexpected end") }
		switch bytes[at] {
		case UInt8(ascii: "{"): return try object(path: path)
		case UInt8(ascii: "["): return try array(path: path)
		case UInt8(ascii: "\""): return .string(try string())
		case UInt8(ascii: "t"): try literal("true"); return .bool(true)
		case UInt8(ascii: "f"): try literal("false"); return .bool(false)
		case UInt8(ascii: "n"): try literal("null"); return .null
		default: return .number(try number())
		}
	}

	private mutating func nest() throws(JSONTreeError) {
		depth += 1
		if depth > 64 { throw error("nested too deeply") }
	}

	private mutating func object(path: String) throws(JSONTreeError) -> JSONTree {
		try nest()
		defer { depth -= 1 }
		at += 1
		var members: [JSONTree.Member] = []
		var seen = Set<String>()
		skipSpace()
		if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object([]) }
		while true {
			skipSpace()
			guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw error("expected a key") }
			let keyLine = line
			let key = try string()
			let memberPath = path.isEmpty ? key : path + "." + key
			if !seen.insert(key).inserted { duplicates.append((memberPath, keyLine)) }
			skipSpace()
			guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw error("expected ':'") }
			at += 1
			skipSpace()
			let valueLine = line
			members.append(JSONTree.Member(key: key, value: try value(path: memberPath), line: valueLine))
			skipSpace()
			guard at < bytes.count else { throw error("unexpected end in an object") }
			if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
			if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(members) }
			throw error("expected ',' or '}'")
		}
	}

	private mutating func array(path: String) throws(JSONTreeError) -> JSONTree {
		try nest()
		defer { depth -= 1 }
		at += 1
		var items: [JSONTree] = []
		skipSpace()
		if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array([]) }
		while true {
			skipSpace()
			items.append(try value(path: path))
			skipSpace()
			guard at < bytes.count else { throw error("unexpected end in an array") }
			if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
			if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
			throw error("expected ',' or ']'")
		}
	}

	private mutating func literal(_ word: String) throws(JSONTreeError) {
		let w = Array(word.utf8)
		guard at + w.count <= bytes.count, Array(bytes[at..<at + w.count]) == w else { throw error("invalid value") }
		at += w.count
	}

	private mutating func number() throws(JSONTreeError) -> Double {
		let start = at
		while at < bytes.count, "+-0123456789.eE".utf8.contains(bytes[at]) { at += 1 }
		guard at > start, let text = String(bytes: bytes[start..<at], encoding: .ascii), let value = Double(text) else {
			throw error("invalid value")
		}
		return value
	}

	private mutating func string() throws(JSONTreeError) -> String {
		at += 1
		var out: [UInt8] = []
		while at < bytes.count {
			let b = bytes[at]
			at += 1
			switch b {
			case UInt8(ascii: "\""):
				guard let s = String(bytes: out, encoding: .utf8) else { throw error("invalid UTF-8") }
				return s
			case UInt8(ascii: "\\"):
				guard at < bytes.count else { throw error("unexpected end in a string") }
				let e = bytes[at]
				at += 1
				switch e {
				case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
				case UInt8(ascii: "n"): out.append(0x0A)
				case UInt8(ascii: "t"): out.append(0x09)
				case UInt8(ascii: "r"): out.append(0x0D)
				case UInt8(ascii: "b"): out.append(0x08)
				case UInt8(ascii: "f"): out.append(0x0C)
				case UInt8(ascii: "u"):
					var scalar = try hex4()
					if (0xD800...0xDBFF).contains(scalar) {
						guard at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") else {
							throw error("invalid surrogate pair")
						}
						at += 2
						let low = try hex4()
						guard (0xDC00...0xDFFF).contains(low) else { throw error("invalid surrogate pair") }
						scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
					}
					guard let u = Unicode.Scalar(scalar) else { throw error("invalid escape") }
					out.append(contentsOf: Array(String(Character(u)).utf8))
				default: throw error("invalid escape")
				}
			case 0x0A: throw error("line break in a string")
			case 0x00..<0x20: throw error("control character in a string")
			default: out.append(b)
			}
		}
		throw error("unexpected end in a string")
	}

	private mutating func hex4() throws(JSONTreeError) -> UInt32 {
		guard at + 4 <= bytes.count, let text = String(bytes: bytes[at..<at + 4], encoding: .ascii),
		      let value = UInt32(text, radix: 16) else { throw error("invalid escape") }
		at += 4
		return value
	}
}
