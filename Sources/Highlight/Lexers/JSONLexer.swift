/// JSON with comments (settings files): strings before ":" are keys.
public struct JSONLexer: Lexer {
	enum Mode: UInt8 { case code = 0, blockComment }

	static let constants = WordSet("true false null")

	public init() {}

	public func lex(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		var s = LineScanner(line)
		while !s.atEnd {
			let start = s.pos
			if state.mode == Mode.blockComment.rawValue {
				while !s.atEnd && !s.starts(with: "*/") { s.pos += 1 }
				if !s.atEnd { s.pos += 2; state.mode = Mode.code.rawValue }
				tokens.append(Token(start, s.pos - start, .comment))
				continue
			}
			let b = s.peek()
			if Bytes.isSpace(b) {
				s.skipSpaces()
			} else if s.starts(with: "//") {
				tokens.append(Token(start, s.count - start, .comment))
				s.pos = s.count
			} else if s.starts(with: "/*") {
				s.pos += 2
				while !s.atEnd && !s.starts(with: "*/") { s.pos += 1 }
				if s.atEnd { state.mode = Mode.blockComment.rawValue } else { s.pos += 2 }
				tokens.append(Token(start, s.pos - start, .comment))
			} else if b == 0x22 {
				s.pos += 1
				let first = tokens.count
				_ = s.scanQuoted(0x22, tokens: &tokens, from: start)
				// A key: the next non-space character is ":".
				var i = s.pos
				while i < s.count && Bytes.isSpace(s[i]) { i += 1 }
				if i < s.count && s[i] == 0x3A {
					for k in first..<tokens.count where tokens[k].kind == .string { tokens[k].kind = .property }
				}
			} else if b == 0x2D || Bytes.isDigit(b) {
				if b == 0x2D { s.pos += 1 }
				if s.scanNumber() { tokens.append(Token(start, s.pos - start, .number)) } else if b != 0x2D { s.pos += 1 }
			} else if Bytes.isIdentStart(b) {
				s.skipIdent()
				tokens.append(Token(start, s.pos - start, JSONLexer.constants.contains(s.slice(start, s.pos)) ? .constant : .invalid))
			} else {
				s.pos += 1
			}
		}
	}
}
