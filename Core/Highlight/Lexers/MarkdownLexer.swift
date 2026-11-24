/// Markdown: headings, lists, quotes, `code`, fenced code blocks, links, **strong** and
/// *emphasis*, HTML comments.
nonisolated public struct MarkdownLexer: Lexer {
	enum Mode: UInt8 { case text = 0, fence, comment }

	public init() {}

	public func lex(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		var s = LineScanner(line)
		s.skipSpaces()
		if state.mode == Mode.fence.rawValue {
			if s.starts(with: "```") || s.starts(with: "~~~") { state.mode = Mode.text.rawValue }
			tokens.append(Token(0, s.count, .string))
			return
		}
		if state.mode == Mode.comment.rawValue {
			while !s.atEnd && !s.starts(with: "-->") { s.pos += 1 }
			if !s.atEnd { s.pos += 3; state.mode = Mode.text.rawValue }
			tokens.append(Token(0, s.pos, .comment))
			if s.atEnd { return }
		}
		if s.starts(with: "```") || s.starts(with: "~~~") {
			state.mode = Mode.fence.rawValue
			tokens.append(Token(0, s.count, .string))
			return
		}
		if s.peek() == 0x23 { // # heading
			tokens.append(Token(s.pos, s.count - s.pos, .keyword))
			return
		}
		if s.peek() == 0x3E { // > quote
			tokens.append(Token(s.pos, s.count - s.pos, .comment))
			return
		}
		// List markers: "- ", "* ", "+ ", "1. ".
		let markerStart = s.pos
		if (s.peek() == 0x2D || s.peek() == 0x2A || s.peek() == 0x2B) && s.peek(1) == 0x20 {
			s.pos += 1
			tokens.append(Token(markerStart, 1, .keyword))
		} else {
			while !s.atEnd && Bytes.isDigit(s.peek()) { s.pos += 1 }
			if s.pos > markerStart && s.peek() == 0x2E && s.peek(1) == 0x20 {
				s.pos += 1
				tokens.append(Token(markerStart, s.pos - markerStart, .keyword))
			} else {
				s.pos = markerStart
			}
		}
		while !s.atEnd {
			let start = s.pos
			let b = s.peek()
			if b == 0x60 { // `code`
				s.pos += 1
				while !s.atEnd && s.peek() != 0x60 { s.pos += 1 }
				if !s.atEnd { s.pos += 1 }
				tokens.append(Token(start, s.pos - start, .string))
			} else if s.starts(with: "<!--") {
				s.pos += 4
				while !s.atEnd && !s.starts(with: "-->") { s.pos += 1 }
				if s.atEnd { state.mode = Mode.comment.rawValue } else { s.pos += 3 }
				tokens.append(Token(start, s.pos - start, .comment))
			} else if b == 0x5B, let close = (s.pos..<s.count).first(where: { s[$0] == 0x5D }), close + 1 < s.count, s[close + 1] == 0x28,
			          let end = ((close + 1)..<s.count).first(where: { s[$0] == 0x29 }) {
				tokens.append(Token(start, close + 1 - start, .function)) // [text]
				tokens.append(Token(close + 1, end + 1 - (close + 1), .string)) // (url)
				s.pos = end + 1
			} else if (b == 0x2A || b == 0x5F) && !Bytes.isSpace(s.peek(1)) && s.peek(1) != 0 && (start == 0 || !Bytes.isIdent(s[start - 1])) {
				let strong = s.peek(1) == b
				let n = strong ? 2 : 1
				var i = s.pos + n
				while i + n <= s.count && !(s[i] == b && (!strong || s[i + 1] == b)) { i += 1 }
				if i + n <= s.count && i > s.pos + n {
					tokens.append(Token(start, i + n - start, strong ? .keyword : .attribute))
					s.pos = i + n
				} else {
					s.pos += n
				}
			} else {
				s.pos += 1
			}
		}
	}
}
