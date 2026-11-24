/// CSS and SCSS: selectors outside blocks, `property: value` inside them (nesting through the
/// mode stack), comments, strings, numbers with units, colours, @rules, !important, $variables.
nonisolated public struct CSSLexer: Lexer {
	enum Mode: UInt8 { case selector = 0, block, comment }

	public init() {}

	public func lex(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		lexSegment(line, state: &state, tokens: &tokens)
	}

	func lexSegment(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		var s = LineScanner(line)
		var inValue = false // after "property:" up to ";" or "}"
		while !s.atEnd {
			let start = s.pos
			if state.mode == Mode.comment.rawValue {
				while !s.atEnd && !s.starts(with: "*/") { s.pos += 1 }
				if !s.atEnd { s.pos += 2; state.pop() }
				tokens.append(Token(start, s.pos - start, .comment))
				continue
			}
			let b = s.peek()
			let inBlock = state.mode == Mode.block.rawValue
			if Bytes.isSpace(b) {
				s.skipSpaces()
			} else if s.starts(with: "/*") {
				s.pos += 2
				state.push(Mode.comment.rawValue)
				while !s.atEnd && !s.starts(with: "*/") { s.pos += 1 }
				if !s.atEnd { s.pos += 2; state.pop() }
				tokens.append(Token(start, s.pos - start, .comment))
			} else if s.starts(with: "//") { // SCSS
				tokens.append(Token(start, s.count - start, .comment))
				s.pos = s.count
			} else if b == 0x7B {
				s.pos += 1
				state.push(Mode.block.rawValue)
				inValue = false
			} else if b == 0x7D {
				s.pos += 1
				state.pop()
				inValue = false
			} else if b == 0x3B {
				s.pos += 1
				inValue = false
			} else if b == 0x22 || b == 0x27 {
				s.pos += 1
				_ = s.scanQuoted(b, tokens: &tokens, from: start)
			} else if b == 0x40 && Bytes.isIdentStart(s.peek(1)) { // @media, @include
				s.pos += 1
				s.skipIdent()
				while !s.atEnd && s.peek() == 0x2D { s.pos += 1; s.skipIdent() }
				tokens.append(Token(start, s.pos - start, .keyword))
				inValue = true // the rule's prelude reads like a value: (max-width: 600px)
			} else if b == 0x24 && Bytes.isIdentStart(s.peek(1)) { // $scss
				s.pos += 1
				skipName(&s)
				tokens.append(Token(start, s.pos - start, .variable))
				if nextIsColon(s) { inValue = true } // $accent: #ff0;
			} else if b == 0x21 && s.startsIgnoringCase(with: "!important") {
				s.pos += 10
				tokens.append(Token(start, 10, .keyword))
			} else if inValue && b == 0x23 && Bytes.isHex(s.peek(1)) { // #fff colour
				s.pos += 1
				while !s.atEnd && Bytes.isHex(s.peek()) { s.pos += 1 }
				tokens.append(Token(start, s.pos - start, .number))
			} else if (inValue || !inBlock) && (Bytes.isDigit(b) || b == 0x2E && Bytes.isDigit(s.peek(1))) && s.scanNumber() {
				while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x25) { s.pos += 1 } // px, %, em
				tokens.append(Token(start, s.pos - start, .number))
			} else if Bytes.isIdentStart(b) || b == 0x2D || ((b == 0x2E || b == 0x23 || b == 0x3A || b == 0x26) && !inValue) {
				if b == 0x2E || b == 0x23 || b == 0x3A || b == 0x26 { s.pos += 1; if b == 0x3A && s.peek() == 0x3A { s.pos += 1 } }
				skipName(&s)
				let isProperty = inBlock && !inValue && nextIsColon(s) && b != 0x3A && b != 0x26
				let kind: TokenKind
				if isProperty {
					kind = .property
					inValue = true
				} else if inValue {
					kind = s.peek() == 0x28 ? .function : .plain
				} else {
					// Selector parts: .class #id :hover element.
					kind = b == 0x2E || b == 0x23 ? .attribute : b == 0x3A ? .keyword : .tag
				}
				if kind != .plain && s.pos > start { tokens.append(Token(start, s.pos - start, kind)) }
				if s.pos == start { s.pos += 1 }
			} else {
				if b == 0x3A && inBlock { inValue = true }
				s.pos += 1
			}
		}
	}

	private func skipName(_ s: inout LineScanner) {
		while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x2D) { s.pos += 1 }
	}

	/// A property name: ":" follows (after spaces) and it is not a selector's ":hover".
	private func nextIsColon(_ s: LineScanner) -> Bool {
		var i = s.pos
		while i < s.count && Bytes.isSpace(s[i]) { i += 1 }
		guard i < s.count && s[i] == 0x3A else { return false }
		// "a:hover {" is a selector: a "{" follows on the line before any ";".
		var j = i + 1
		while j < s.count {
			if s[j] == 0x3B || s[j] == 0x7D { return true }
			if s[j] == 0x7B { return false }
			j += 1
		}
		return true
	}
}
