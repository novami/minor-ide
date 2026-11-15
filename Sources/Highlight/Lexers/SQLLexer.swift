/// SQL for MySQL/MariaDB and PostgreSQL: keywords in any case, '' and \' in strings,
/// `backtick` and "double" identifiers, -- # /* */ comments, ? :name $1 placeholders.
public struct SQLLexer: Lexer {
	enum Mode: UInt8 { case code = 0, blockComment, single }

	static let keywords = WordSet("""
		add all alter and any as asc auto_increment begin between by cascade case check collate column
		commit constraint create cross database default delete desc distinct drop else end engine
		escape exists explain foreign from full grant group having if ignore in index inner insert
		interval into is join key left like limit lock not null offset on or order outer primary
		procedure references rename replace returning right rollback schema select set show table
		temporary then to transaction trigger truncate union unique unsigned update use using values
		view when where while with window over partition recursive conflict do nothing lateral
		""", caseInsensitive: true)
	static let types = WordSet("""
		bigint binary bit blob bool boolean char date datetime decimal double enum float int integer
		json jsonb longtext mediumint mediumtext numeric real serial smallint text time timestamp
		timestamptz tinyint tinytext uuid varbinary varchar bytea
		""", caseInsensitive: true)
	static let constants = WordSet("true false null current_timestamp current_date", caseInsensitive: true)

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
			if state.mode == Mode.single.rawValue {
				scanSingle(&s, &state, &tokens)
				continue
			}
			let b = s.peek()
			if Bytes.isSpace(b) {
				s.skipSpaces()
			} else if s.starts(with: "--") || b == 0x23 {
				tokens.append(Token(start, s.count - start, .comment))
				s.pos = s.count
			} else if s.starts(with: "/*") {
				s.pos += 2
				while !s.atEnd && !s.starts(with: "*/") { s.pos += 1 }
				if s.atEnd { state.mode = Mode.blockComment.rawValue } else { s.pos += 2 }
				tokens.append(Token(start, s.pos - start, .comment))
			} else if b == 0x27 {
				s.pos += 1
				tokens.append(Token(start, 1, .string))
				state.mode = Mode.single.rawValue
				scanSingle(&s, &state, &tokens)
			} else if b == 0x60 || b == 0x22 {
				s.pos += 1
				while !s.atEnd && s.peek() != b { s.pos += 1 }
				if !s.atEnd { s.pos += 1 }
				tokens.append(Token(start, s.pos - start, .property))
			} else if b == 0x3F || (b == 0x3A && Bytes.isIdentStart(s.peek(1))) || (b == 0x24 && Bytes.isDigit(s.peek(1))) {
				s.pos += 1
				s.skipIdent()
				tokens.append(Token(start, s.pos - start, .variable))
			} else if b == 0x3A && s.peek(1) == 0x3A { // ::type cast
				s.pos += 2
			} else if s.scanNumber() {
				tokens.append(Token(start, s.pos - start, .number))
			} else if Bytes.isIdentStart(b) {
				s.skipIdent()
				let word = s.slice(start, s.pos)
				var kind: TokenKind = .plain
				if SQLLexer.constants.contains(word) {
					kind = .constant
				} else if SQLLexer.keywords.contains(word) {
					kind = .keyword
				} else if SQLLexer.types.contains(word) {
					kind = .type
				} else if s.peek() == 0x28 {
					kind = .function
				}
				if kind != .plain { tokens.append(Token(start, s.pos - start, kind)) }
			} else {
				s.pos += 1
			}
		}
	}

	private func scanSingle(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token]) {
		var segment = s.pos
		while !s.atEnd {
			let b = s.peek()
			if (b == 0x27 && s.peek(1) == 0x27) || (b == 0x5C && s.pos + 1 < s.count) {
				if s.pos > segment { tokens.append(Token(segment, s.pos - segment, .string)) }
				tokens.append(Token(s.pos, 2, .escape))
				s.pos += 2
				segment = s.pos
				continue
			}
			s.pos += 1
			if b == 0x27 {
				state.mode = Mode.code.rawValue
				break
			}
		}
		if s.pos > segment { tokens.append(Token(segment, s.pos - segment, .string)) }
	}
}
