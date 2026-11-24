/// NEON (Nette configuration): `key:` keys, '…' "…" and '''/""" multi-line strings, # comments,
/// @service and %parameter% references, entities Name(…), constants yes/no/on/off/true/false/null.
nonisolated public struct NEONLexer: Lexer {
	enum Mode: UInt8 { case code = 0, tripleSingle, tripleDouble }

	static let constants = WordSet("true false yes no on off null TRUE FALSE YES NO ON OFF NULL True False Yes No On Off Null")

	public init() {}

	public func lex(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		var s = LineScanner(line)
		if state.mode != Mode.code.rawValue {
			// A multi-line string ends on a line holding only the closing quotes.
			let closing: StaticString = state.mode == Mode.tripleSingle.rawValue ? "'''" : "\"\"\""
			s.skipSpaces()
			if s.starts(with: closing) {
				state.mode = Mode.code.rawValue
				s.pos += 3
				tokens.append(Token(0, s.pos, .string))
			} else {
				tokens.append(Token(0, s.count, .string))
				return
			}
		}
		// At a key position: the line start, after "- ", "{", "(" or ",".
		var keyPosition = true
		while !s.atEnd {
			let start = s.pos
			let b = s.peek()
			if Bytes.isSpace(b) {
				s.skipSpaces()
				continue
			}
			if b == 0x23 && (start == 0 || Bytes.isSpace(s[start - 1])) {
				tokens.append(Token(start, s.count - start, .comment))
				return
			}
			if s.starts(with: "'''") || s.starts(with: "\"\"\"") {
				state.mode = b == 0x27 ? Mode.tripleSingle.rawValue : Mode.tripleDouble.rawValue
				tokens.append(Token(start, s.count - start, .string))
				return
			}
			if b == 0x27 || b == 0x22 {
				s.pos += 1
				let first = tokens.count
				_ = s.scanQuoted(b, escapes: b == 0x22, tokens: &tokens, from: start)
				if keyPosition && isColon(s, s.pos) {
					for k in first..<tokens.count where tokens[k].kind == .string { tokens[k].kind = .property }
				}
				keyPosition = false
				continue
			}
			if b == 0x2D && (s.peek(1) == 0x20 || s.pos + 1 == s.count) {
				s.pos += 1
				keyPosition = true
				continue
			}
			if b == 0x7B || b == 0x28 || b == 0x2C || b == 0x5B {
				s.pos += 1
				keyPosition = b != 0x5B
				continue
			}
			if b == 0x40 && (Bytes.isIdentStart(s.peek(1)) || s.peek(1) == 0x5C) { // @service
				s.pos += 1
				while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x5C || s.peek() == 0x2E) { s.pos += 1 }
				tokens.append(Token(start, s.pos - start, .variable))
				keyPosition = false
				continue
			}
			if b == 0x25, let end = s.bytes[(s.base + s.pos + 1)...].firstIndex(of: 0x25), !s.bytes[(s.base + s.pos + 1)..<end].contains(0x20) {
				s.pos = end - s.base + 1 // %parameter%
				tokens.append(Token(start, s.pos - start, .variable))
				keyPosition = false
				continue
			}
			if s.scanNumber(), s.atEnd || !Bytes.isIdent(s.peek()) {
				tokens.append(Token(start, s.pos - start, .number))
				keyPosition = false
				continue
			}
			s.pos = start
			if Bytes.isIdentStart(b) || b == 0x5C {
				// Unquoted literal up to a delimiter: a key, a constant, an entity or plain text.
				while !s.atEnd {
					let c = s.peek()
					if c == 0x3A && (s.pos + 1 == s.count || Bytes.isSpace(s.peek(1))) { break }
					if c == 0x2C || c == 0x28 || c == 0x29 || c == 0x5D || c == 0x7D || c == 0x3D || c == 0x23 && Bytes.isSpace(s[s.pos - 1]) { break }
					s.pos += 1
				}
				var end = s.pos
				while end > start && Bytes.isSpace(s[end - 1]) { end -= 1 }
				let word = s.slice(start, end)
				if keyPosition && isColon(s, s.pos) {
					tokens.append(Token(start, end - start, .property))
				} else if NEONLexer.constants.contains(word) {
					tokens.append(Token(start, end - start, .constant))
				} else if s.peek() == 0x28 {
					tokens.append(Token(start, end - start, .function))
				} else if word.contains(0x5C) {
					tokens.append(Token(start, end - start, .type))
				}
				keyPosition = false
				continue
			}
			s.pos += 1
			if b == 0x3A || b == 0x3D { keyPosition = false }
		}
	}

	/// ":" followed by a space or the line end (a key), possibly after spaces.
	private func isColon(_ s: LineScanner, _ at: Int) -> Bool {
		var i = at
		while i < s.count && Bytes.isSpace(s[i]) { i += 1 }
		return i < s.count && s[i] == 0x3A && (i + 1 == s.count || Bytes.isSpace(s[i + 1]))
	}
}
