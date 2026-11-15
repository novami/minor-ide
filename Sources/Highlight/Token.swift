/// What a token is; themes map kinds to colours. Plain text is not stored as tokens.
public enum TokenKind: UInt8, Sendable, CaseIterable, Codable {
	case plain, keyword, type, function, string, escape, number, constant, comment, variable
	case property, tag, attribute, macro, invalid

	public var name: String { String(describing: self) }
}

/// A token inside one line; offsets are bytes from the line start.
public struct Token: Sendable, Equatable {
	public var start: Int
	public var length: Int
	public var kind: TokenKind

	public init(_ start: Int, _ length: Int, _ kind: TokenKind) {
		self.start = start
		self.length = length
		self.kind = kind
	}

	public var end: Int { start + length }
}

/// Lexer state at a line start: the mode, a stack of enclosing modes (embedded languages)
/// and text the mode needs (a heredoc delimiter). Equal states mean equal lexing from there,
/// which is what stops incremental relexing.
public struct LexState: Hashable, Sendable {
	public var mode: UInt8
	public var stack: [UInt8]
	public var text: [UInt8]

	public init(mode: UInt8 = 0, stack: [UInt8] = [], text: [UInt8] = []) {
		self.mode = mode
		self.stack = stack
		self.text = text
	}

	public static let start = LexState()

	public mutating func push(_ newMode: UInt8) {
		stack.append(mode)
		mode = newMode
	}

	public mutating func pop() {
		mode = stack.popLast() ?? 0
	}
}

/// A line lexer: a state machine over the bytes of one line (without the newline).
public protocol Lexer: Sendable {
	/// Appends the line's tokens in order and leaves `state` at the start of the next line.
	func lex(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token])
}

/// Byte classes shared by the lexers. Bytes >= 0x80 (UTF-8) count as identifier characters.
enum Bytes {
	@inline(__always) static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
	@inline(__always) static func isHex(_ b: UInt8) -> Bool { isDigit(b) || (b | 0x20 >= 0x61 && b | 0x20 <= 0x66) }
	@inline(__always) static func isIdentStart(_ b: UInt8) -> Bool {
		(b | 0x20 >= 0x61 && b | 0x20 <= 0x7A) || b == 0x5F || b >= 0x80
	}
	@inline(__always) static func isIdent(_ b: UInt8) -> Bool { isIdentStart(b) || isDigit(b) }
	@inline(__always) static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D }
}

/// Keywords looked up without allocating: up to 24 bytes packed into three integers.
struct WordSet: Sendable {
	private struct Key: Hashable {
		var a: UInt64, b: UInt64, c: UInt64, n: Int
	}

	private var words: Set<Key> = []
	private let caseInsensitive: Bool

	init(_ list: String, caseInsensitive: Bool = false) {
		self.caseInsensitive = caseInsensitive
		for w in list.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
			let bytes = Array(w.utf8)
			if let k = key(bytes[...]) { words.insert(k) }
		}
	}

	private func key(_ s: ArraySlice<UInt8>) -> Key? {
		guard s.count <= 24 else { return nil }
		var a: UInt64 = 0, b: UInt64 = 0, c: UInt64 = 0
		for (i, var ch) in s.enumerated() {
			if caseInsensitive && ch >= 0x41 && ch <= 0x5A { ch |= 0x20 }
			if i < 8 { a |= UInt64(ch) << (i * 8) } else if i < 16 { b |= UInt64(ch) << ((i - 8) * 8) } else { c |= UInt64(ch) << ((i - 16) * 8) }
		}
		return Key(a: a, b: b, c: c, n: s.count)
	}

	func contains(_ s: ArraySlice<UInt8>) -> Bool {
		guard let k = key(s) else { return false }
		return words.contains(k)
	}
}

/// Cursor over a line with helpers for the common token shapes. Positions are relative to
/// the line start, whatever the slice's indices are.
struct LineScanner {
	let bytes: ArraySlice<UInt8>
	let base: Int
	let count: Int
	var pos = 0

	init(_ bytes: ArraySlice<UInt8>) {
		self.bytes = bytes
		base = bytes.startIndex
		count = bytes.count
	}

	@inline(__always) subscript(i: Int) -> UInt8 { bytes[base + i] }

	func slice(_ a: Int, _ b: Int) -> ArraySlice<UInt8> { bytes[(base + a)..<(base + b)] }

	var atEnd: Bool { pos >= count }
	@inline(__always) func peek(_ offset: Int = 0) -> UInt8 {
		pos + offset < count ? bytes[base + pos + offset] : 0
	}

	func starts(with s: StaticString, at i: Int? = nil) -> Bool {
		let at = i ?? pos
		let n = s.utf8CodeUnitCount
		guard at + n <= count else { return false }
		return s.withUTF8Buffer { buf in
			for k in 0..<n where self[at + k] != buf[k] { return false }
			return true
		}
	}

	/// Case-insensitive ASCII prefix test.
	func startsIgnoringCase(with s: StaticString, at i: Int? = nil) -> Bool {
		let at = i ?? pos
		let n = s.utf8CodeUnitCount
		guard at + n <= count else { return false }
		return s.withUTF8Buffer { buf in
			for k in 0..<n where self[at + k] | 0x20 != buf[k] | 0x20 { return false }
			return true
		}
	}

	mutating func skipSpaces() { while !atEnd && Bytes.isSpace(self[pos]) { pos += 1 } }

	mutating func skipIdent() { while !atEnd && Bytes.isIdent(self[pos]) { pos += 1 } }

	/// Number literal: decimal, 0x/0b/0o, underscores, fraction, exponent; returns false if none.
	mutating func scanNumber() -> Bool {
		let start = pos
		if peek() == 0x2E { // .5
			guard Bytes.isDigit(peek(1)) else { return false }
		} else if !Bytes.isDigit(peek()) {
			return false
		}
		if peek() == 0x30, [0x78, 0x58, 0x62, 0x42, 0x6F, 0x4F].contains(peek(1)) {
			pos += 2
			while !atEnd && (Bytes.isHex(self[pos]) || self[pos] == 0x5F) { pos += 1 }
		} else {
			while !atEnd && (Bytes.isDigit(self[pos]) || self[pos] == 0x5F) { pos += 1 }
			if peek() == 0x2E && Bytes.isDigit(peek(1)) || (peek() == 0x2E && start == pos) {
				pos += 1
				while !atEnd && (Bytes.isDigit(self[pos]) || self[pos] == 0x5F) { pos += 1 }
			} else if peek() == 0x2E && !Bytes.isIdentStart(peek(1)) && peek(1) != 0x2E {
				pos += 1 // "1." is a float
			}
			if peek() | 0x20 == 0x65, Bytes.isDigit(peek(1)) || ((peek(1) == 0x2B || peek(1) == 0x2D) && Bytes.isDigit(peek(2))) {
				pos += 2
				while !atEnd && Bytes.isDigit(self[pos]) { pos += 1 }
			}
		}
		return pos > start
	}

	/// Quoted string body after the opening quote: stops after `quote` or at the line end.
	/// Backslash escapes become escape tokens when `escapes` is set. True when closed.
	mutating func scanQuoted(_ quote: UInt8, escapes: Bool = true, kind: TokenKind = .string, tokens: inout [Token], from start: Int) -> Bool {
		var segment = start
		while !atEnd {
			let b = self[pos]
			if b == 0x5C && pos + 1 < count {
				if escapes {
					if pos > segment { tokens.append(Token(segment, pos - segment, kind)) }
					tokens.append(Token(pos, 2, .escape))
					pos += 2
					segment = pos
				} else {
					pos += 2
				}
				continue
			}
			pos += 1
			if b == quote {
				tokens.append(Token(segment, pos - segment, kind))
				return true
			}
		}
		if pos > segment { tokens.append(Token(segment, pos - segment, kind)) }
		return false
	}
}
