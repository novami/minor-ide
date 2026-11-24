/// Shell scripts, and with `dockerfile` / `makefile` set also Dockerfiles (instructions at the
/// line start) and Makefiles (targets, $(variables)). `.env` files use `env`: KEY=value.
nonisolated public struct ShellLexer: Lexer {
	public enum Flavor: Sendable { case shell, dockerfile, makefile, env }
	enum Mode: UInt8 { case code = 0, single, double, heredoc }

	let flavor: Flavor

	static let keywords = WordSet("""
		if then else elif fi for while until do done case esac in function select return exit
		local export readonly declare set unset shift break continue source alias eval exec trap
		""")
	static let instructions = WordSet("""
		FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL
		HEALTHCHECK SHELL MAINTAINER AS
		""", caseInsensitive: true)

	public init(_ flavor: Flavor = .shell) { self.flavor = flavor }

	public func lex(_ line: ArraySlice<UInt8>, state: inout LexState, tokens: inout [Token]) {
		var s = LineScanner(line)
		if state.mode == Mode.heredoc.rawValue {
			// <<EOF … EOF: the body ends on a line holding only the delimiter.
			var i = 0
			while i < s.count && s[i] == 0x09 { i += 1 }
			if Array(s.slice(i, s.count)) == state.text { state.mode = Mode.code.rawValue; state.text = [] }
			tokens.append(Token(0, s.count, .string))
			return
		}
		var first = true // first word of a command
		if flavor == .env {
			s.skipSpaces()
			if s.peek() == 0x23 { tokens.append(Token(s.pos, s.count - s.pos, .comment)); return }
			let start = s.pos
			if s.starts(with: "export ") { s.pos += 7; tokens.append(Token(start, 6, .keyword)) }
			let key = s.pos
			while !s.atEnd && s.peek() != 0x3D { s.pos += 1 }
			if s.pos > key { tokens.append(Token(key, s.pos - key, .property)) }
			if !s.atEnd { s.pos += 1 }
			first = false
		}
		if flavor == .makefile, !s.atEnd, s.peek() != 0x09, s.peek() != 0x23 {
			// "target: deps" and "VAR := value" lines.
			var i = 0
			while i < s.count && s[i] != 0x3A && s[i] != 0x3D && s[i] != 0x20 { i += 1 }
			if i < s.count && s[i] == 0x3A && (i + 1 == s.count || s[i + 1] != 0x3D) && i > 0 {
				tokens.append(Token(0, i, .function))
				s.pos = i + 1
				first = false
			} else if i > 0, i < s.count {
				var j = i
				while j < s.count && s[j] == 0x20 { j += 1 }
				if j < s.count && (s[j] == 0x3D || (s[j] == 0x3A || s[j] == 0x3F || s[j] == 0x2B) && j + 1 < s.count && s[j + 1] == 0x3D) {
					tokens.append(Token(0, i, .property))
					s.pos = i
					first = false
				}
			}
		}
		while !s.atEnd {
			let start = s.pos
			if state.mode == Mode.single.rawValue {
				while !s.atEnd && s.peek() != 0x27 { s.pos += 1 }
				if !s.atEnd { s.pos += 1; state.mode = Mode.code.rawValue }
				tokens.append(Token(start, s.pos - start, .string))
				continue
			}
			if state.mode == Mode.double.rawValue {
				lexDouble(&s, &state, &tokens)
				continue
			}
			let b = s.peek()
			if Bytes.isSpace(b) {
				s.skipSpaces()
			} else if b == 0x23 && (start == 0 || Bytes.isSpace(s[start - 1])) {
				tokens.append(Token(start, s.count - start, .comment))
				return
			} else if b == 0x27 {
				s.pos += 1
				state.mode = Mode.single.rawValue
				tokens.append(Token(start, 1, .string))
			} else if b == 0x22 {
				s.pos += 1
				state.mode = Mode.double.rawValue
				tokens.append(Token(start, 1, .string))
			} else if b == 0x24 {
				scanVariable(&s, &tokens)
				first = false
			} else if s.starts(with: "<<"), flavor != .makefile {
				var i = s.pos + 2
				if i < s.count && s[i] == 0x2D { i += 1 }
				while i < s.count && (s[i] == 0x27 || s[i] == 0x22 || s[i] == 0x20) { i += 1 }
				let name = i
				while i < s.count && Bytes.isIdent(s[i]) { i += 1 }
				if i > name {
					state.text = Array(s.slice(name, i))
					state.mode = Mode.heredoc.rawValue
					while i < s.count && (s[i] == 0x27 || s[i] == 0x22) { i += 1 }
					tokens.append(Token(start, i - start, .string))
					s.pos = i
				} else {
					s.pos += 2
				}
			} else if Bytes.isDigit(b) && (start == 0 || !Bytes.isIdent(s[start - 1])) && s.scanNumber() {
				tokens.append(Token(start, s.pos - start, .number))
				first = false
			} else if Bytes.isIdentStart(b) || b == 0x2D {
				while !s.atEnd && (Bytes.isIdent(s.peek()) || s.peek() == 0x2D || s.peek() == 0x2E || s.peek() == 0x2F) { s.pos += 1 }
				let word = s.slice(start, s.pos)
				if flavor == .dockerfile && start == 0 && ShellLexer.instructions.contains(word) {
					tokens.append(Token(start, s.pos - start, .keyword))
					first = true // RUN apt-get …: a command follows
					continue
				} else if ShellLexer.keywords.contains(word) {
					tokens.append(Token(start, s.pos - start, .keyword))
					first = true // if/then/do … are followed by a command
					continue
				} else if s.peek() == 0x3D && b != 0x2D {
					tokens.append(Token(start, s.pos - start, .property)) // NAME=value
				} else if b == 0x2D {
					tokens.append(Token(start, s.pos - start, .attribute)) // --option
				} else if first {
					tokens.append(Token(start, s.pos - start, .function))
				}
				first = false
			} else {
				s.pos += 1
				if b == 0x7C || b == 0x3B || b == 0x26 || b == 0x28 || b == 0x60 { first = true }
			}
		}
	}

	private func scanVariable(_ s: inout LineScanner, _ tokens: inout [Token]) {
		let start = s.pos
		s.pos += 1
		let open = s.peek()
		if open == 0x7B || open == 0x28 { // ${VAR} $(VAR) $(cmd)
			let close: UInt8 = open == 0x7B ? 0x7D : 0x29
			var depth = 0
			while !s.atEnd {
				if s.peek() == open { depth += 1 } else if s.peek() == close { depth -= 1; if depth == 0 { s.pos += 1; break } }
				s.pos += 1
			}
		} else if Bytes.isIdentStart(open) || Bytes.isDigit(open) || "@?#$!*-".utf8.contains(open) {
			s.pos += 1
			if Bytes.isIdentStart(open) { s.skipIdent() }
		}
		tokens.append(Token(start, s.pos - start, .variable))
	}

	private func lexDouble(_ s: inout LineScanner, _ state: inout LexState, _ tokens: inout [Token]) {
		var segment = s.pos
		while !s.atEnd {
			let b = s.peek()
			if b == 0x5C && s.pos + 1 < s.count {
				if s.pos > segment { tokens.append(Token(segment, s.pos - segment, .string)) }
				tokens.append(Token(s.pos, 2, .escape))
				s.pos += 2
				segment = s.pos
			} else if b == 0x24 && s.pos + 1 < s.count && s.peek(1) != 0x22 {
				if s.pos > segment { tokens.append(Token(segment, s.pos - segment, .string)) }
				scanVariable(&s, &tokens)
				segment = s.pos
			} else {
				s.pos += 1
				if b == 0x22 { state.mode = Mode.code.rawValue; break }
			}
		}
		if s.pos > segment { tokens.append(Token(segment, s.pos - segment, .string)) }
	}
}
