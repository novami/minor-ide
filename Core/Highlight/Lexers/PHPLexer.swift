/// PHP with the HTML around it. HTML mode handles tags, attributes and comments; `<?php` and
/// `<?=` push PHP mode (also inside attribute values), `?>` pops back. Strings, block and doc
/// comments, heredoc and nowdoc continue over lines.
nonisolated public struct PHPLexer: Lexer {
	enum Mode: UInt8 {
		case html = 0, php, single, double, block, doc, heredoc, nowdoc, htmlComment, htmlTag, attrDouble, attrSingle
	}

	static let keywords = WordSet("""
		abstract and as break case catch clone const continue declare default die do echo else elseif
		__halt_compiler empty enddeclare endfor endforeach endif endswitch endwhile enum eval exit extends final
		finally fn for foreach function global goto if implements include include_once instanceof
		insteadof interface isset list match namespace new or print private protected public readonly
		require require_once return static switch throw trait try unset use var while xor yield
		""", caseInsensitive: true)
	static let types = WordSet("int float bool string array mixed void never iterable object callable self parent null false true", caseInsensitive: true)
	static let constants = WordSet("true false null __class__ __dir__ __file__ __function__ __line__ __method__ __namespace__ __trait__ __property__", caseInsensitive: true)
	/// Keywords after which a name is a class name.
	static let classContext = WordSet("class interface trait enum extends implements new instanceof namespace use insteadof", caseInsensitive: true)

	public init() {}

	public func lex(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		var s = LineScanner(line)
		var after: UInt8 = 0 // 1: function name follows, 2: class name follows, 3: member after -> or ::
		// A heredoc or nowdoc ends on a line starting (after indentation) with its delimiter.
		if state.mode == Mode.heredoc.rawValue || state.mode == Mode.nowdoc.rawValue {
			var i = 0
			while i < s.count && Bytes.isSpace(s[i]) { i += 1 }
			let d = state.text
			if i + d.count <= s.count, s.slice(i, i + d.count).elementsEqual(d), i + d.count == s.count || !Bytes.isIdent(s[i + d.count]) {
				tokens.append(Token(i, d.count, .string))
				s.pos = i + d.count
				state.mode = Mode.php.rawValue
				state.text = []
			}
		}
		while !s.atEnd {
			let start = s.pos
			switch Mode(rawValue: state.mode) ?? .html {
			case .html:
				lexHTML(&s, &state, &tokens)
			case .htmlComment:
				while !s.atEnd && !s.starts(with: "-->") { s.pos += 1 }
				if !s.atEnd { s.pos += 3; state.mode = Mode.html.rawValue }
				tokens.append(Token(start, s.pos - start, .comment))
			case .htmlTag:
				lexTag(&s, &state, &tokens)
			case .attrDouble, .attrSingle:
				let quote: UInt8 = state.mode == Mode.attrDouble.rawValue ? 0x22 : 0x27
				while !s.atEnd && s.peek() != quote && !openPHP(&s, &state, &tokens, flushFrom: start) { s.pos += 1 }
				if state.mode == Mode.php.rawValue { continue } // openPHP flushed the text before it
				if !s.atEnd { s.pos += 1; state.mode = Mode.htmlTag.rawValue }
				tokens.append(Token(start, s.pos - start, .string))
			case .single:
				lexSingle(&s, &state, &tokens)
			case .double, .heredoc:
				lexInterpolated(&s, &state, &tokens, closing: state.mode == Mode.double.rawValue ? 0x22 : nil)
			case .nowdoc:
				tokens.append(Token(start, s.count - start, .string))
				s.pos = s.count
			case .block, .doc:
				let doc = state.mode == Mode.doc.rawValue
				var segment = start
				while !s.atEnd && !s.starts(with: "*/") {
					if doc && s.peek() == 0x40 && Bytes.isIdentStart(s.peek(1)) && (s.pos == 0 || !Bytes.isIdent(s[s.pos - 1])) {
						if s.pos > segment { tokens.append(Token(segment, s.pos - segment, .comment)) }
						let tag = s.pos
						s.pos += 1
						s.skipIdent()
						tokens.append(Token(tag, s.pos - tag, .attribute))
						segment = s.pos
						continue
					}
					s.pos += 1
				}
				if !s.atEnd { s.pos += 2; state.mode = Mode.php.rawValue }
				if s.pos > segment { tokens.append(Token(segment, s.pos - segment, .comment)) }
			case .php:
				lexPHP(&s, &state, &tokens, after: &after)
			}
		}
	}

	/// `<?php`, `<?=` or a short `<?` at the position: emits it, pushes PHP mode and flushes
	/// the text before it (from `flushFrom`) as a string token.
	private func openPHP(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token], flushFrom: Int? = nil) -> Bool {
		guard s.peek() == 0x3C, s.peek(1) == 0x3F else { return false }
		var n = 2
		if s.startsIgnoringCase(with: "<?php") { n = 5 } else if s.peek(2) == 0x3D { n = 3 }
		if let from = flushFrom, s.pos > from { tokens.append(Token(from, s.pos - from, .string)) }
		tokens.append(Token(s.pos, n, .keyword))
		s.pos += n
		state.push(Mode.php.rawValue)
		return true
	}

	private func lexHTML(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token]) {
		let start = s.pos
		if openPHP(&s, &state, &tokens) { return }
		if s.starts(with: "<!--") {
			s.pos += 4
			state.mode = Mode.htmlComment.rawValue
			while !s.atEnd && !s.starts(with: "-->") { s.pos += 1 }
			if !s.atEnd { s.pos += 3; state.mode = Mode.html.rawValue }
			tokens.append(Token(start, s.pos - start, .comment))
		} else if s.peek() == 0x3C && (Bytes.isIdentStart(s.peek(1)) || s.peek(1) == 0x2F || s.peek(1) == 0x21) {
			s.pos += s.peek(1) == 0x2F || s.peek(1) == 0x21 ? 2 : 1
			while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x2D || s.peek() == 0x3A) { s.pos += 1 }
			tokens.append(Token(start, s.pos - start, .tag))
			state.mode = Mode.htmlTag.rawValue
		} else if s.peek() == 0x26 { // &entity;
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
			while !s.atEnd && s.peek() != 0x3C && s.peek() != 0x26 { s.pos += 1 }
		}
	}

	private func lexTag(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token]) {
		let start = s.pos
		let b = s.peek()
		if openPHP(&s, &state, &tokens) { return }
		if Bytes.isSpace(b) {
			s.skipSpaces()
		} else if b == 0x3E || (b == 0x2F && s.peek(1) == 0x3E) || (b == 0x3F && s.peek(1) == 0x3E) {
			s.pos += b == 0x3E ? 1 : 2
			tokens.append(Token(start, s.pos - start, .tag))
			state.mode = Mode.html.rawValue
		} else if b == 0x22 || b == 0x27 {
			s.pos += 1
			state.mode = b == 0x22 ? Mode.attrDouble.rawValue : Mode.attrSingle.rawValue
			while !s.atEnd && s.peek() != b && !openPHP(&s, &state, &tokens, flushFrom: start) { s.pos += 1 }
			if state.mode == Mode.php.rawValue { return }
			if !s.atEnd { s.pos += 1; state.mode = Mode.htmlTag.rawValue }
			tokens.append(Token(start, s.pos - start, .string))
		} else if Bytes.isIdentStart(b) || b == 0x40 || b == 0x3A {
			s.pos += 1
			while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x2D || s.peek() == 0x3A || s.peek() == 0x2E) { s.pos += 1 }
			tokens.append(Token(start, s.pos - start, .attribute))
		} else {
			s.pos += 1
		}
	}

	private func lexSingle(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token]) {
		var segment = s.pos
		while !s.atEnd {
			let b = s.peek()
			if b == 0x5C && (s.peek(1) == 0x27 || s.peek(1) == 0x5C) {
				if s.pos > segment { tokens.append(Token(segment, s.pos - segment, .string)) }
				tokens.append(Token(s.pos, 2, .escape))
				s.pos += 2
				segment = s.pos
				continue
			}
			s.pos += 1
			if b == 0x27 {
				state.mode = Mode.php.rawValue
				break
			}
		}
		if s.pos > segment { tokens.append(Token(segment, s.pos - segment, .string)) }
	}

	/// Double-quoted string or heredoc body: escapes, `$var`, `$obj->prop`, `{$…}`.
	private func lexInterpolated(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token], closing: UInt8?) {
		var segment = s.pos
		func flush(_ s: LineScanner) {
			if s.pos > segment { tokens.append(Token(segment, s.pos - segment, .string)) }
		}
		while !s.atEnd {
			let b = s.peek()
			if b == 0x5C && s.pos + 1 < s.count {
				flush(s)
				tokens.append(Token(s.pos, 2, .escape))
				s.pos += 2
				segment = s.pos
			} else if b == 0x24 && Bytes.isIdentStart(s.peek(1)) || (b == 0x7B && s.peek(1) == 0x24) {
				flush(s)
				let v = s.pos
				if b == 0x7B { s.pos += 1 }
				s.pos += 1
				s.skipIdent()
				if s.starts(with: "->") && Bytes.isIdentStart(s.peek(2)) {
					s.pos += 2
					s.skipIdent()
				}
				if b == 0x7B { while !s.atEnd && s.peek() != 0x7D { s.pos += 1 }; if !s.atEnd { s.pos += 1 } }
				tokens.append(Token(v, s.pos - v, .variable))
				segment = s.pos
			} else {
				s.pos += 1
				if let closing, b == closing {
					state.mode = Mode.php.rawValue
					break
				}
			}
		}
		flush(s)
	}

	private func lexPHP(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token], after: inout UInt8) {
		let start = s.pos
		let b = s.peek()
		if Bytes.isSpace(b) {
			s.skipSpaces()
			return
		}
		if s.starts(with: "?>") {
			s.pos += 2
			tokens.append(Token(start, 2, .keyword))
			state.pop()
			if state.mode == Mode.php.rawValue { state.mode = Mode.html.rawValue }
			return
		}
		if s.starts(with: "//") || (b == 0x23 && s.peek(1) != 0x5B) {
			// A line comment ends at the line end or at "?>".
			while !s.atEnd && !s.starts(with: "?>") { s.pos += 1 }
			tokens.append(Token(start, s.pos - start, .comment))
			return
		}
		if s.starts(with: "#[") {
			s.pos += 1
			var depth = 0
			repeat {
				if s.peek() == 0x5B { depth += 1 } else if s.peek() == 0x5D { depth -= 1 }
				s.pos += 1
			} while !s.atEnd && depth > 0
			tokens.append(Token(start, s.pos - start, .attribute))
			return
		}
		if s.starts(with: "/*") {
			let doc = s.starts(with: "/**") && s.peek(3) != 0x2F
			s.pos += doc ? 3 : 2
			tokens.append(Token(start, s.pos - start, .comment))
			state.mode = doc ? Mode.doc.rawValue : Mode.block.rawValue
			return
		}
		if b == 0x27 {
			s.pos += 1
			tokens.append(Token(start, 1, .string))
			state.mode = Mode.single.rawValue
			return
		}
		if b == 0x22 {
			s.pos += 1
			tokens.append(Token(start, 1, .string))
			state.mode = Mode.double.rawValue
			return
		}
		if s.starts(with: "<<<") {
			var i = s.pos + 3
			while i < s.count && Bytes.isSpace(s[i]) { i += 1 }
			let quote: UInt8? = i < s.count && (s[i] == 0x27 || s[i] == 0x22) ? s[i] : nil
			if quote != nil { i += 1 }
			let nameStart = i
			while i < s.count && Bytes.isIdent(s[i]) { i += 1 }
			if i > nameStart {
				state.text = Array(s.slice(nameStart, i))
				if quote != nil && i < s.count && s[i] == quote { i += 1 }
				tokens.append(Token(start, i - start, .string))
				s.pos = i
				state.mode = quote == 0x27 ? Mode.nowdoc.rawValue : Mode.heredoc.rawValue
				return
			}
		}
		if b == 0x24 && (Bytes.isIdentStart(s.peek(1)) || s.peek(1) == 0x24) {
			s.pos += 1
			while s.peek() == 0x24 { s.pos += 1 }
			s.skipIdent()
			tokens.append(Token(start, s.pos - start, .variable))
			after = 0
			return
		}
		if s.scanNumber() {
			tokens.append(Token(start, s.pos - start, .number))
			after = 0
			return
		}
		if Bytes.isIdentStart(b) || (b == 0x5C && Bytes.isIdentStart(s.peek(1))) {
			// Names with namespaces: App\Model\User.
			while !s.atEnd && (Bytes.isIdent(s.peek()) || (s.peek() == 0x5C && Bytes.isIdentStart(s.peek(1)))) { s.pos += 1 }
			let word = s.slice(start, s.pos)
			var next = s.pos
			while next < s.count && Bytes.isSpace(s[next]) { next += 1 }
			let call = next < s.count && s[next] == 0x28
			var kind: TokenKind = .plain
			if after == 3 {
				kind = call ? .function : (isUpper(word) ? .constant : word.count == 5 && PHPLexer.classContext.contains(word) ? .keyword : .property)
				after = 0
			} else if after == 1 {
				kind = .function
				after = 0
			} else if PHPLexer.keywords.contains(word) || PHPLexer.classContext.contains(word) {
				kind = .keyword
				if word.count == 8 && word.first! | 0x20 == 0x66 { after = 1 } // function
				else if PHPLexer.classContext.contains(word) { after = 2 }
			} else if after == 2 {
				kind = .type
			} else if PHPLexer.constants.contains(word) {
				kind = .constant
			} else if call {
				kind = .function
			} else if PHPLexer.types.contains(word) {
				kind = .type
			} else if isUpper(word) {
				kind = .constant
			} else if let first = word.first(where: { $0 != 0x5C }), first >= 0x41 && first <= 0x5A {
				kind = .type
			}
			if kind != .plain { tokens.append(Token(start, s.pos - start, kind)) }
			return
		}
		// Operators and punctuation.
		if s.starts(with: "->") || s.starts(with: "::") {
			s.pos += 2
			after = 3
			return
		}
		if s.starts(with: "?->") {
			s.pos += 3
			after = 3
			return
		}
		if b == 0x2C || b == 0x3B || b == 0x28 || b == 0x29 || b == 0x7B || b == 0x7D || b == 0x3D {
			if after != 2 || b != 0x2C { after = 0 } // "implements A, B" keeps class context
		}
		s.pos += 1
	}

	/// ALL_CAPS names (at least two characters) read as constants.
	private func isUpper(_ word: ArraySlice<UInt8>) -> Bool {
		var letters = 0
		for c in word {
			if c >= 0x61 && c <= 0x7A { return false }
			if c >= 0x41 && c <= 0x5A { letters += 1 }
		}
		return letters > 1
	}
}
