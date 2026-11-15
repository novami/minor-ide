/// Go (spec: go.dev/ref/spec). Modes: block comment, raw string.
public struct GoLexer: Lexer {
	enum Mode: UInt8 { case code = 0, blockComment, rawString }

	static let keywords = WordSet("""
		break case chan const continue default defer else fallthrough for func go goto if import
		interface map package range return select struct switch type var
		""")
	static let types = WordSet("""
		any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64
		rune string uint uint8 uint16 uint32 uint64 uintptr
		""")
	static let constants = WordSet("true false iota nil")

	public init() {}

	public func lex(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		var s = LineScanner(line)
		// Previous keyword: the name after "func" is a function, after "type" a type.
		var after: UInt8 = 0 // 1 func, 2 type
		while !s.atEnd {
			switch Mode(rawValue: state.mode) ?? .code {
			case .blockComment:
				let start = s.pos
				while !s.atEnd && !s.starts(with: "*/") { s.pos += 1 }
				if !s.atEnd { s.pos += 2; state.mode = Mode.code.rawValue }
				tokens.append(Token(start, s.pos - start, .comment))
			case .rawString:
				let start = s.pos
				while !s.atEnd && s.peek() != 0x60 { s.pos += 1 }
				if !s.atEnd { s.pos += 1; state.mode = Mode.code.rawValue }
				tokens.append(Token(start, s.pos - start, .string))
			case .code:
				let start = s.pos
				let b = s.peek()
				if Bytes.isSpace(b) {
					s.skipSpaces()
				} else if s.starts(with: "//") {
					tokens.append(Token(start, s.count - start, .comment))
					s.pos = s.count
				} else if s.starts(with: "/*") {
					s.pos += 2
					state.mode = Mode.blockComment.rawValue
					while !s.atEnd && !s.starts(with: "*/") { s.pos += 1 }
					if !s.atEnd { s.pos += 2; state.mode = Mode.code.rawValue }
					tokens.append(Token(start, s.pos - start, .comment))
				} else if b == 0x22 || b == 0x27 { // " '
					s.pos += 1
					_ = s.scanQuoted(b, tokens: &tokens, from: start)
				} else if b == 0x60 { // `
					s.pos += 1
					state.mode = Mode.rawString.rawValue
					while !s.atEnd && s.peek() != 0x60 { s.pos += 1 }
					if !s.atEnd { s.pos += 1; state.mode = Mode.code.rawValue }
					tokens.append(Token(start, s.pos - start, .string))
				} else if s.scanNumber() {
					if s.peek() == 0x69 { s.pos += 1 } // imaginary
					tokens.append(Token(start, s.pos - start, .number))
				} else if Bytes.isIdentStart(b) {
					s.skipIdent()
					let word = s.slice(start, s.pos)
					var kind: TokenKind = .plain
					if GoLexer.keywords.contains(word) {
						kind = .keyword
						after = s.pos - start == 4 && s[start] == 0x66 ? 1 : (s.pos - start == 4 && s[start] == 0x74 ? 2 : 0)
						tokens.append(Token(start, s.pos - start, kind))
						continue
					} else if after == 2 || GoLexer.types.contains(word) {
						kind = .type
					} else if GoLexer.constants.contains(word) {
						kind = .constant
					} else if s.peek() == 0x28 || (after == 1 && s.peek() == 0x5B) { // call, or generic func Name[T]
						kind = .function
					}
					after = 0
					if kind != .plain { tokens.append(Token(start, s.pos - start, kind)) }
				} else {
					// A receiver "func (r T) Name(" keeps "after func" across the parenthesis.
					if b != 0x28 && b != 0x29 && b != 0x2A && b != 0x5B && b != 0x5D { after = 0 }
					s.pos += 1
				}
			}
		}
	}
}
