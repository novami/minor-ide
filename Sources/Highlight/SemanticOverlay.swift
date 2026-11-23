/// Colouring from a language server's semantic tokens laid over the lexer's tokens. The lexer
/// stays the base (it is instant and knows strings, comments and keywords); semantic tokens
/// only recolour names the lexer cannot tell apart.
extension TokenKind {
	/// The kind for a standard semantic token type, nil when the lexer's colour stays.
	public init?(semanticType type: String, modifiers: [String]) {
		switch type {
		case "type", "class", "enum", "interface", "struct", "typeParameter": self = .type
		case "function", "method": self = .function
		case "property": self = .property
		case "enumMember": self = .constant
		case "macro": self = .macro
		case "variable" where modifiers.contains("readonly"): self = .constant
		default: return nil
		}
	}

	/// Lexer kinds a semantic token may replace: plain text and names.
	var isName: Bool {
		switch self {
		case .plain, .type, .function, .variable, .property, .constant: true
		default: false
		}
	}
}

extension Token {
	/// `base` (sorted lexer tokens of a line) with the `semantic` tokens (sorted) laid over
	/// it. A semantic token that overlaps a non-name lexer token or an earlier semantic token
	/// is ignored.
	public static func overlay(_ base: [Token], _ semantic: [Token]) -> [Token] {
		if semantic.isEmpty { return base }
		var accepted: [Token] = []
		accepted.reserveCapacity(semantic.count)
		var b = 0, end = 0
		for s in semantic where s.length > 0 && s.start >= end {
			while b < base.count && base[b].end <= s.start { b += 1 }
			var k = b, ok = true
			while k < base.count && base[k].start < s.end {
				if !base[k].kind.isName { ok = false; break }
				k += 1
			}
			if ok {
				accepted.append(s)
				end = s.end
			}
		}
		if accepted.isEmpty { return base }
		var out: [Token] = []
		out.reserveCapacity(base.count + accepted.count * 2)
		var i = 0, emitted = -1
		for t in base {
			var pos = t.start
			while i < accepted.count && accepted[i].start < t.end {
				let a = accepted[i]
				if a.start > pos { out.append(Token(pos, a.start - pos, t.kind)) }
				if emitted < i {
					out.append(a)
					emitted = i
				}
				pos = max(pos, a.end)
				if a.end > t.end { break }
				i += 1
			}
			if pos < t.end { out.append(Token(pos, t.end - pos, t.kind)) }
		}
		while i < accepted.count {
			if emitted < i { out.append(accepted[i]) }
			i += 1
		}
		return out
	}
}
