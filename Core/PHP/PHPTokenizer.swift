/// PHP 7.2 to 8.5 tokenizer over raw UTF-8 bytes. It never fails and never traps: every byte
/// belongs to exactly one token, unknown bytes become `.illegal`.
///
/// Hot loops run over an `UnsafeBufferPointer`; every read goes through `byte(at:)`, which
/// returns 0 past the end, so no access can leave the buffer.
nonisolated public enum PHPTokenKind: UInt8, Sendable {
	case eof, inlineHTML, openTag, closeTag, whitespace, comment, docComment
	case variable, ident, name, number, string, heredoc, op, attrOpen, illegal
}

/// 12 bytes. Text is sliced from the source by offsets on demand.
nonisolated public struct PHPToken: Equatable, Sendable {
	public var kind: PHPTokenKind
	/// Single-character operator byte, or one of the `PHPOp` codes for multi-character ones, else 0.
	public var op: UInt8
	public var start: Int32
	public var end: Int32
}

/// Codes for multi-character operators the scanner needs to tell apart (values below any ASCII operator).
nonisolated public enum PHPOp {
	public static let doubleColon: UInt8 = 1   // ::
	public static let arrow: UInt8 = 2         // ->
	public static let nullsafe: UInt8 = 3      // ?->
	public static let other: UInt8 = 4         // any other multi-character operator
}

/// Files larger than this are not tokenized (offsets are `Int32`).
nonisolated public let phpMaxSourceSize = Int(Int32.max) - 16

nonisolated public struct PHPTokenizer {
	let src: UnsafeBufferPointer<UInt8>
	let count: Int
	var pos = 0
	var inPHP = false

	public init(_ src: UnsafeBufferPointer<UInt8>) {
		self.src = src
		count = min(src.count, phpMaxSourceSize)
	}

	@inline(__always) func byte(at i: Int) -> UInt8 { i >= 0 && i < count ? src[i] : 0 }
	@inline(__always) func peek(_ n: Int) -> UInt8 { byte(at: pos + n) }

	/// Next token; keeps returning `.eof` at the end.
	public mutating func next() -> PHPToken {
		let start = pos
		if pos >= count { return PHPToken(kind: .eof, op: 0, start: Int32(count), end: Int32(count)) }
		let (kind, op) = inPHP ? php() : inlineHTML()
		if pos <= start { pos = start + 1 } // safety net: always make progress
		if pos > count { pos = count } // `\\` or a quote at the very end may step past it
		return PHPToken(kind: kind, op: op, start: Int32(truncatingIfNeeded: start), end: Int32(truncatingIfNeeded: pos))
	}

	// MARK: Inline HTML

	mutating func inlineHTML() -> (PHPTokenKind, UInt8) {
		let n = openTagLength(at: pos)
		if n > 0 {
			pos += n
			inPHP = true
			return (.openTag, 0)
		}
		var i = pos + 1
		while i < count {
			if src[i] == UInt8(ascii: "<"), byte(at: i + 1) == UInt8(ascii: "?"), openTagLength(at: i) > 0 { break }
			i += 1
		}
		pos = i
		return (.inlineHTML, 0)
	}

	func openTagLength(at p: Int) -> Int {
		guard byte(at: p) == UInt8(ascii: "<"), byte(at: p + 1) == UInt8(ascii: "?") else { return 0 }
		if byte(at: p + 2) | 0x20 == UInt8(ascii: "p"), byte(at: p + 3) | 0x20 == UInt8(ascii: "h"), byte(at: p + 4) | 0x20 == UInt8(ascii: "p") {
			if p + 5 >= count { return p + 5 == count ? 5 : 0 }
			let c = src[p + 5]
			guard phpIsSpace(c) else { return 0 }
			return c == UInt8(ascii: "\r") && byte(at: p + 6) == UInt8(ascii: "\n") ? 7 : 6
		}
		return byte(at: p + 2) == UInt8(ascii: "=") ? 3 : 2
	}

	// MARK: PHP code

	mutating func php() -> (PHPTokenKind, UInt8) {
		let c = src[pos]
		if phpIsSpace(c) {
			while pos < count, phpIsSpace(src[pos]) { pos += 1 }
			return (.whitespace, 0)
		}
		switch c {
		case UInt8(ascii: "?") where peek(1) == UInt8(ascii: ">"):
			pos += 2
			if peek(0) == UInt8(ascii: "\n") { pos += 1 } else if peek(0) == UInt8(ascii: "\r"), peek(1) == UInt8(ascii: "\n") { pos += 2 }
			inPHP = false
			return (.closeTag, 0)
		case UInt8(ascii: "#"):
			if peek(1) == UInt8(ascii: "[") { pos += 2; return (.attrOpen, 0) }
			lineComment()
			return (.comment, 0)
		case UInt8(ascii: "/") where peek(1) == UInt8(ascii: "/"):
			lineComment()
			return (.comment, 0)
		case UInt8(ascii: "/") where peek(1) == UInt8(ascii: "*"):
			let doc = peek(2) == UInt8(ascii: "*") && phpIsSpace(peek(3))
			pos = find(UInt8(ascii: "*"), UInt8(ascii: "/"), from: pos + 2).map { $0 + 2 } ?? count
			return (doc ? .docComment : .comment, 0)
		case UInt8(ascii: "$") where phpIsIdentStart(peek(1)):
			pos += 1
			ident()
			return (.variable, 0)
		case UInt8(ascii: "\\") where phpIsIdentStart(peek(1)):
			name()
			return (.name, 0)
		case UInt8(ascii: "'"), UInt8(ascii: "\""), UInt8(ascii: "`"):
			quoted(c)
			return (.string, 0)
		case UInt8(ascii: "<") where peek(1) == UInt8(ascii: "<") && peek(2) == UInt8(ascii: "<"):
			if heredoc() { return (.heredoc, 0) }
		default:
			if phpIsIdentStart(c) {
				ident()
				if peek(0) == UInt8(ascii: "\\"), phpIsIdentStart(peek(1)) { name(); return (.name, 0) }
				return (.ident, 0)
			}
			if phpIsDigit(c) || (c == UInt8(ascii: ".") && phpIsDigit(peek(1))) {
				number()
				return (.number, 0)
			}
		}
		let (n, code) = operatorAt(pos)
		if n > 0 {
			pos += n
			return (.op, code)
		}
		pos += 1
		return (.illegal, 0)
	}

	/// Offset of the two-byte sequence `a b` at or after `from`.
	func find(_ a: UInt8, _ b: UInt8, from: Int) -> Int? {
		var i = from
		while i + 1 < count {
			if src[i] == a, src[i + 1] == b { return i }
			i += 1
		}
		return nil
	}

	mutating func lineComment() {
		while pos < count {
			let c = src[pos]
			if c == UInt8(ascii: "\n") || c == UInt8(ascii: "\r") { return }
			if c == UInt8(ascii: "?"), peek(1) == UInt8(ascii: ">") { return } // ?> ends a line comment
			pos += 1
		}
	}

	@inline(__always) mutating func ident() {
		while pos < count, phpIsIdentChar(src[pos]) { pos += 1 }
	}

	mutating func name() {
		while peek(0) == UInt8(ascii: "\\"), phpIsIdentStart(peek(1)) {
			pos += 1
			ident()
		}
	}

	mutating func number() {
		if src[pos] == UInt8(ascii: "0") {
			switch peek(1) | 0x20 {
			case UInt8(ascii: "x"), UInt8(ascii: "b"), UInt8(ascii: "o"):
				pos += 2
				while pos < count, phpIsHex(src[pos]) || src[pos] == UInt8(ascii: "_") { pos += 1 }
				return
			default: break
			}
		}
		digits()
		// "1." without digits after the dot lexes as 1 and the "." operator (rare).
		if peek(0) == UInt8(ascii: "."), phpIsDigit(peek(1)) {
			pos += 1
			digits()
		}
		if peek(0) | 0x20 == UInt8(ascii: "e") {
			let n = peek(1) == UInt8(ascii: "+") || peek(1) == UInt8(ascii: "-") ? 2 : 1
			if phpIsDigit(peek(n)) {
				pos += n
				digits()
			}
		}
	}

	@inline(__always) mutating func digits() {
		while pos < count, phpIsDigit(src[pos]) || (src[pos] == UInt8(ascii: "_") && phpIsDigit(peek(1))) { pos += 1 }
	}

	mutating func quoted(_ q: UInt8) {
		pos += 1
		while pos < count {
			let c = src[pos]
			if c == UInt8(ascii: "\\") { pos += 2; continue }
			pos += 1
			if c == q { return }
		}
		pos = count
	}

	/// `<<<LABEL … LABEL` with the PHP 7.3 flexible syntax, also nowdoc. Returns false without
	/// moving when this is not a heredoc start.
	mutating func heredoc() -> Bool {
		var p = pos + 3
		while p < count, src[p] == UInt8(ascii: " ") || src[p] == UInt8(ascii: "\t") { p += 1 }
		var quote: UInt8 = 0
		if byte(at: p) == UInt8(ascii: "'") || byte(at: p) == UInt8(ascii: "\"") { quote = src[p]; p += 1 }
		let labelStart = p
		while p < count, phpIsIdentChar(src[p]) { p += 1 }
		guard p > labelStart, phpIsIdentStart(src[labelStart]) else { return false }
		let labelLength = p - labelStart
		if quote != 0 {
			guard byte(at: p) == quote else { return false }
			p += 1
		}
		if byte(at: p) == UInt8(ascii: "\r") { p += 1 }
		guard byte(at: p) == UInt8(ascii: "\n") else { return false }
		p += 1
		while p < count {
			var q = p
			while q < count, src[q] == UInt8(ascii: " ") || src[q] == UInt8(ascii: "\t") { q += 1 }
			if matches(at: q, labelStart, labelLength), !phpIsIdentChar(byte(at: q + labelLength)) {
				pos = q + labelLength
				return true
			}
			while p < count, src[p] != UInt8(ascii: "\n") { p += 1 }
			p += 1
		}
		pos = count
		return true
	}

	func matches(at p: Int, _ other: Int, _ length: Int) -> Bool {
		guard p + length <= count else { return false }
		for k in 0..<length where src[p + k] != src[other + k] { return false }
		return true
	}

	/// Length and code of the operator at `p`, longest match first; (0, 0) when none.
	func operatorAt(_ p: Int) -> (Int, UInt8) {
		let a = src[p], b = byte(at: p + 1), c = byte(at: p + 2)
		switch a {
		case UInt8(ascii: ":") where b == UInt8(ascii: ":"): return (2, PHPOp.doubleColon)
		case UInt8(ascii: "-") where b == UInt8(ascii: ">"): return (2, PHPOp.arrow)
		case UInt8(ascii: "?") where b == UInt8(ascii: "-") && c == UInt8(ascii: ">"): return (3, PHPOp.nullsafe)
		default: break
		}
		if let n = Self.multiOperators[Int(a)].first(where: { op in op.indices.allSatisfy { byte(at: p + $0) == op[$0] } })?.count {
			return (n, PHPOp.other)
		}
		return Self.singleOperators[Int(a)] ? (1, a) : (0, 0)
	}

	/// Multi-character operators indexed by first byte, longest first.
	static let multiOperators: [[[UInt8]]] = {
		let ops = ["<<=", ">>=", "**=", "...", "<=>", "===", "!==", "??=", "|>",
		           "<<", ">>", "**", "++", "--", "=>", "==", "!=", "<>", "<=", ">=",
		           "&&", "||", "??", "+=", "-=", "*=", "/=", ".=", "%=", "&=", "|=", "^="]
		var table = [[[UInt8]]](repeating: [], count: 256)
		for op in ops.sorted(by: { $0.utf8.count > $1.utf8.count }) {
			let bytes = Array(op.utf8)
			table[Int(bytes[0])].append(bytes)
		}
		return table
	}()

	static let singleOperators: [Bool] = {
		var t = [Bool](repeating: false, count: 256)
		for c in "+-*/%=<>!.&|^~?:;,()[]{}@$\\".utf8 { t[Int(c)] = true }
		return t
	}()
}

// MARK: Character classes

nonisolated private let clsSpace: UInt8 = 1, clsDigit: UInt8 = 2, clsIdentStart: UInt8 = 4, clsHex: UInt8 = 8

nonisolated private let charClass: [UInt8] = (0..<256).map { c -> UInt8 in
	let b = UInt8(c)
	var cls: UInt8 = 0
	if b == 0x20 || (b >= 0x09 && b <= 0x0D) { cls |= clsSpace }
	if b >= 0x30 && b <= 0x39 { cls |= clsDigit | clsHex }
	let lower = b | 0x20
	if b == UInt8(ascii: "_") || (lower >= 0x61 && lower <= 0x7A) || b >= 0x80 { cls |= clsIdentStart }
	if lower >= 0x61 && lower <= 0x66 { cls |= clsHex }
	return cls
}

@inline(__always) nonisolated private func phpIsSpace(_ c: UInt8) -> Bool { charClass[Int(c)] & clsSpace != 0 }
@inline(__always) nonisolated private func phpIsDigit(_ c: UInt8) -> Bool { charClass[Int(c)] & clsDigit != 0 }
@inline(__always) nonisolated private func phpIsHex(_ c: UInt8) -> Bool { charClass[Int(c)] & clsHex != 0 }
@inline(__always) nonisolated private func phpIsIdentStart(_ c: UInt8) -> Bool { charClass[Int(c)] & clsIdentStart != 0 }
@inline(__always) nonisolated private func phpIsIdentChar(_ c: UInt8) -> Bool { charClass[Int(c)] & (clsIdentStart | clsDigit) != 0 }
