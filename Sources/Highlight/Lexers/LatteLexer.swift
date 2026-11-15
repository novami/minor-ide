/// Latte templates: HTML with `{tags}` (PHP expressions inside, `|filters`), `{* comments *}`
/// and `n:attributes`. Tags work everywhere, inside attribute values and <script>/<style> too
/// (a tag starts with "{" followed directly by a letter, $, /, =, _, *, \ or !). Script and
/// style bodies stay plain text until JS and CSS lexers exist (phase 1f).
public struct LatteLexer: Lexer {
	enum Mode: UInt8 {
		case html = 0, htmlComment, htmlTag, attrDouble, attrSingle, latte, latteComment, nAttrDouble, nAttrSingle, script, style
	}

	static let keywords = WordSet("as in instanceof new and or not xor fn function use match default", caseInsensitive: true)
	static let constants = WordSet("true false null", caseInsensitive: true)

	public init() {}

	public func lex(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		var s = LineScanner(line)
		while !s.atEnd {
			let start = s.pos
			switch Mode(rawValue: state.mode) ?? .html {
			case .html:
				lexHTML(&s, &state, &tokens)
			case .htmlComment:
				while !s.atEnd && !s.starts(with: "-->") && !openLatte(&s, &state, &tokens, flushFrom: start, kind: .comment) { s.pos += 1 }
				if state.mode != Mode.htmlComment.rawValue { continue }
				if !s.atEnd { s.pos += 3; state.mode = Mode.html.rawValue }
				tokens.append(Token(start, s.pos - start, .comment))
			case .htmlTag:
				lexTag(&s, &state, &tokens)
			case .attrDouble, .attrSingle:
				let quote: UInt8 = state.mode == Mode.attrDouble.rawValue ? 0x22 : 0x27
				while !s.atEnd && s.peek() != quote && !openLatte(&s, &state, &tokens, flushFrom: start, kind: .string) { s.pos += 1 }
				if state.mode == Mode.latte.rawValue || state.mode == Mode.latteComment.rawValue { continue }
				if !s.atEnd { s.pos += 1; state.mode = Mode.htmlTag.rawValue }
				if s.pos > start { tokens.append(Token(start, s.pos - start, .string)) }
			case .latte:
				lexExpression(&s, &state, &tokens, closing: 0x7D)
			case .nAttrDouble, .nAttrSingle:
				lexExpression(&s, &state, &tokens, closing: state.mode == Mode.nAttrDouble.rawValue ? 0x22 : 0x27)
			case .latteComment:
				while !s.atEnd && !s.starts(with: "*}") { s.pos += 1 }
				if !s.atEnd { s.pos += 2; state.pop() }
				tokens.append(Token(start, s.pos - start, .comment))
			case .script, .style:
				let end: StaticString = state.mode == Mode.script.rawValue ? "</script" : "</style"
				while !s.atEnd && !s.startsIgnoringCase(with: end) && !openLatte(&s, &state, &tokens) { s.pos += 1 }
				if state.mode == Mode.latte.rawValue || state.mode == Mode.latteComment.rawValue { continue }
				if !s.atEnd {
					state.mode = Mode.html.rawValue
					state.text = []
				}
			}
		}
	}

	/// A Latte tag or comment at the position: emits the text before it (from `flushFrom`)
	/// with `kind`, then the opening, and pushes the tag or comment mode.
	private func openLatte(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token], flushFrom: Int? = nil, kind: TokenKind = .plain) -> Bool {
		guard s.peek() == 0x7B else { return false }
		let c = s.peek(1)
		guard Bytes.isIdentStart(c) && c < 0x80 || c == 0x24 || c == 0x2F || c == 0x3D || c == 0x2A || c == 0x5C || c == 0x21 else { return false }
		if let from = flushFrom, s.pos > from, kind != .plain { tokens.append(Token(from, s.pos - from, kind)) }
		let start = s.pos
		if c == 0x2A {
			s.pos += 2
			state.push(Mode.latteComment.rawValue)
			while !s.atEnd && !s.starts(with: "*}") { s.pos += 1 }
			if !s.atEnd { s.pos += 2; state.pop() }
			tokens.append(Token(start, s.pos - start, .comment))
			return true
		}
		s.pos += 1
		if c == 0x2F || c == 0x3D || c == 0x21 { s.pos += 1 } // {/if} {=expr} {!expr}
		if Bytes.isIdentStart(s.peek()) && s.peek() != 0x5F || s.peek() == 0x5F && !Bytes.isIdent(s.peek(1)) {
			// Tag name ({if}, {foreach}, {_} translation).
			while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x3A) { s.pos += 1 }
		}
		tokens.append(Token(start, s.pos - start, .macro))
		state.push(Mode.latte.rawValue)
		return true
	}

	private func lexHTML(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token]) {
		let start = s.pos
		if openLatte(&s, &state, &tokens) { return }
		if s.starts(with: "<!--") {
			s.pos += 4
			tokens.append(Token(start, 4, .comment))
			state.mode = Mode.htmlComment.rawValue
		} else if s.peek() == 0x3C && (Bytes.isIdentStart(s.peek(1)) || s.peek(1) == 0x2F || s.peek(1) == 0x21) {
			s.pos += s.peek(1) == 0x2F || s.peek(1) == 0x21 ? 2 : 1
			let name = s.pos
			while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x2D || s.peek() == 0x3A) { s.pos += 1 }
			tokens.append(Token(start, s.pos - start, .tag))
			// <script> and <style> bodies are not HTML; remember which one is open.
			let opening = s[start + 1] != 0x2F
			state.text = opening && (s.startsIgnoringCase(with: "script", at: name) && s.pos - name == 6
				|| s.startsIgnoringCase(with: "style", at: name) && s.pos - name == 5) ? Array(s.slice(name, s.pos)) : []
			state.mode = Mode.htmlTag.rawValue
		} else if s.peek() == 0x26 {
			var i = s.pos + 1
			while i < s.count && (Bytes.isIdent(s[i]) || s[i] == 0x23) && i - s.pos < 12 { i += 1 }
			if i < s.count && s[i] == 0x3B && i > s.pos + 1 {
				tokens.append(Token(start, i + 1 - start, .escape))
				s.pos = i + 1
			} else {
				s.pos += 1
			}
		} else {
			s.pos += 1
			while !s.atEnd && s.peek() != 0x3C && s.peek() != 0x26 && s.peek() != 0x7B { s.pos += 1 }
		}
	}

	private func lexTag(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token]) {
		let start = s.pos
		let b = s.peek()
		if openLatte(&s, &state, &tokens) { return }
		if Bytes.isSpace(b) {
			s.skipSpaces()
		} else if b == 0x3E || (b == 0x2F && s.peek(1) == 0x3E) {
			s.pos += b == 0x3E ? 1 : 2
			tokens.append(Token(start, s.pos - start, .tag))
			if b == 0x3E && !state.text.isEmpty {
				state.mode = state.text.count == 6 ? Mode.script.rawValue : Mode.style.rawValue
			} else {
				state.mode = Mode.html.rawValue
				state.text = []
			}
		} else if b == 0x22 || b == 0x27 {
			s.pos += 1
			state.mode = b == 0x22 ? Mode.attrDouble.rawValue : Mode.attrSingle.rawValue
			tokens.append(Token(start, 1, .string))
		} else if Bytes.isIdentStart(b) || b == 0x40 || b == 0x3A {
			s.pos += 1
			while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x2D || s.peek() == 0x3A || s.peek() == 0x2E) { s.pos += 1 }
			let nAttribute = s.starts(with: "n:", at: start)
			tokens.append(Token(start, s.pos - start, nAttribute ? .macro : .attribute))
			// n:attribute="expression"
			if nAttribute, s.peek() == 0x3D, s.peek(1) == 0x22 || s.peek(1) == 0x27 {
				let q = s.peek(1)
				s.pos += 1
				tokens.append(Token(s.pos, 1, .macro))
				s.pos += 1
				state.mode = q == 0x22 ? Mode.nAttrDouble.rawValue : Mode.nAttrSingle.rawValue
			}
		} else {
			s.pos += 1
		}
	}

	/// PHP-like expression inside a tag or an n:attribute, up to `closing`.
	private func lexExpression(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token], closing: UInt8) {
		let start = s.pos
		let b = s.peek()
		if b == closing {
			s.pos += 1
			tokens.append(Token(start, 1, .macro))
			if closing == 0x7D { state.pop() } else { state.mode = Mode.htmlTag.rawValue }
			return
		}
		if Bytes.isSpace(b) {
			s.skipSpaces()
		} else if b == 0x24 && Bytes.isIdentStart(s.peek(1)) {
			s.pos += 1
			s.skipIdent()
			tokens.append(Token(start, s.pos - start, .variable))
		} else if (b == 0x27 || b == 0x22) && b != closing {
			s.pos += 1
			_ = s.scanQuoted(b, escapes: true, tokens: &tokens, from: start)
		} else if b == 0x7C && Bytes.isIdentStart(s.peek(1)) { // |filter
			s.pos += 1
			s.skipIdent()
			tokens.append(Token(start, s.pos - start, .function))
		} else if s.starts(with: "->") || s.starts(with: "::") || s.starts(with: "?->") {
			s.pos += s.peek() == 0x3F ? 3 : 2
			let name = s.pos
			s.skipIdent()
			if s.pos > name {
				tokens.append(Token(name, s.pos - name, s.peek() == 0x28 ? .function : .property))
			}
		} else if s.scanNumber() {
			tokens.append(Token(start, s.pos - start, .number))
		} else if Bytes.isIdentStart(b) || b == 0x5C {
			while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x5C) { s.pos += 1 }
			let word = s.slice(start, s.pos)
			let kind: TokenKind
			if LatteLexer.constants.contains(word) {
				kind = .constant
			} else if LatteLexer.keywords.contains(word) {
				kind = .keyword
			} else if s.peek() == 0x28 {
				kind = .function
			} else if let first = word.first(where: { $0 != 0x5C }), first >= 0x41 && first <= 0x5A {
				kind = word.allSatisfy({ !($0 >= 0x61 && $0 <= 0x7A) }) && word.count > 1 ? .constant : .type
			} else {
				kind = .plain
			}
			if kind != .plain { tokens.append(Token(start, s.pos - start, kind)) }
		} else if b == 0x7B { // nested braces: {var $a = {…}} is rare; keep the tag open
			s.pos += 1
		} else {
			s.pos += 1
		}
	}
}
