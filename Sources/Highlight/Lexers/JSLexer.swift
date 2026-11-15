/// JavaScript and TypeScript: comments, strings, template literals over lines, regex literals,
/// numbers, keywords. Also embedded in Latte <script> bodies, where a line is lexed in pieces
/// between Latte tags (`lexSegment`), so string modes carry over between the pieces.
public struct JSLexer: Lexer {
	enum Mode: UInt8 { case code = 0, blockComment, template, single, double }

	static let keywords = WordSet("""
		async await break case catch class const continue debugger default delete do else export
		extends finally for from function get if import in instanceof let new of return set static
		super switch throw try typeof var void while with yield
		as declare enum implements interface keyof namespace private protected public readonly type
		""")
	static let constants = WordSet("true false null undefined NaN Infinity this")
	static let types = WordSet("any boolean number string symbol unknown never object bigint")

	public init() {}

	public func lex(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		JSLexer.resetLineModes(&state)
		lexSegment(line, state: &state, tokens: &tokens)
	}

	/// Strings in quotes end with the line (an unclosed one is an error, not a continuation).
	static func resetLineModes(_ state: inout LexState) {
		if state.mode == Mode.single.rawValue || state.mode == Mode.double.rawValue { state.mode = Mode.code.rawValue }
	}

	/// Lexes part of a line; token offsets are relative to the slice.
	func lexSegment(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		var s = LineScanner(line)
		// Last significant byte: decides whether "/" starts a regex or divides.
		var last: UInt8 = 0
		var lastWasWord = false
		while !s.atEnd {
			let start = s.pos
			switch Mode(rawValue: state.mode) ?? .code {
			case .blockComment:
				while !s.atEnd && !s.starts(with: "*/") { s.pos += 1 }
				if !s.atEnd { s.pos += 2; state.mode = Mode.code.rawValue }
				tokens.append(Token(start, s.pos - start, .comment))
			case .template:
				while !s.atEnd && s.peek() != 0x60 {
					if s.peek() == 0x5C { s.pos += 1 }
					s.pos += 1
				}
				if !s.atEnd { s.pos += 1; state.mode = Mode.code.rawValue }
				tokens.append(Token(start, min(s.pos, s.count) - start, .string))
				s.pos = min(s.pos, s.count)
			case .single, .double:
				let quote: UInt8 = state.mode == Mode.single.rawValue ? 0x27 : 0x22
				if s.scanQuoted(quote, tokens: &tokens, from: start) { state.mode = Mode.code.rawValue }
				last = quote
				lastWasWord = false
			case .code:
				let b = s.peek()
				if Bytes.isSpace(b) {
					s.skipSpaces()
					continue
				}
				if s.starts(with: "//") {
					tokens.append(Token(start, s.count - start, .comment))
					s.pos = s.count
				} else if s.starts(with: "/*") {
					s.pos += 2
					state.mode = Mode.blockComment.rawValue
					while !s.atEnd && !s.starts(with: "*/") { s.pos += 1 }
					if !s.atEnd { s.pos += 2; state.mode = Mode.code.rawValue }
					tokens.append(Token(start, s.pos - start, .comment))
				} else if b == 0x27 || b == 0x22 {
					s.pos += 1
					state.mode = b == 0x27 ? Mode.single.rawValue : Mode.double.rawValue
					if s.scanQuoted(b, tokens: &tokens, from: start) { state.mode = Mode.code.rawValue }
					last = b
					lastWasWord = false
				} else if b == 0x60 {
					s.pos += 1
					state.mode = Mode.template.rawValue
					while !s.atEnd && s.peek() != 0x60 {
						if s.peek() == 0x5C { s.pos += 1 }
						s.pos += 1
					}
					if !s.atEnd { s.pos += 1; state.mode = Mode.code.rawValue }
					s.pos = min(s.pos, s.count)
					tokens.append(Token(start, s.pos - start, .string))
					last = b
					lastWasWord = false
				} else if b == 0x2F && !lastWasWord && (last == 0 || "(,=:[!&|?{};+-*%<>~^".utf8.contains(last)) {
					// Regex literal: /…/flags, classes [/] included.
					s.pos += 1
					var inClass = false
					while !s.atEnd {
						let c = s.peek()
						if c == 0x5C { s.pos += 2; continue }
						if c == 0x5B { inClass = true } else if c == 0x5D { inClass = false } else if c == 0x2F && !inClass { break }
						s.pos += 1
					}
					if !s.atEnd { s.pos += 1; s.skipIdent() }
					s.pos = min(s.pos, s.count)
					tokens.append(Token(start, s.pos - start, .string))
					last = 0x2F
					lastWasWord = true
				} else if s.scanNumber() {
					if s.peek() == 0x6E { s.pos += 1 } // BigInt
					tokens.append(Token(start, s.pos - start, .number))
					last = 0x30
					lastWasWord = true
				} else if Bytes.isIdentStart(b) || b == 0x24 {
					s.pos += 1
					while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x24) { s.pos += 1 }
					let word = s.slice(start, s.pos)
					var kind: TokenKind = .plain
					if JSLexer.keywords.contains(word) {
						kind = .keyword
					} else if JSLexer.constants.contains(word) {
						kind = .constant
					} else if s.peek() == 0x28 {
						kind = .function
					} else if JSLexer.types.contains(word) || (word.first.map { $0 >= 0x41 && $0 <= 0x5A } ?? false) {
						kind = .type
					}
					if kind != .plain { tokens.append(Token(start, s.pos - start, kind)) }
					// After a keyword like "return" a "/" starts a regex.
					lastWasWord = kind != .keyword
					last = kind == .keyword ? 0x3D : 0x61
				} else {
					s.pos += 1
					last = b
					lastWasWord = b == 0x29 || b == 0x5D
				}
			}
		}
	}
}
