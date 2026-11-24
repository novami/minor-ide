import Foundation

/// Documentation the server sends (hover, signature help): Markdown split into code blocks and
/// prose, or plain text.
nonisolated public enum MarkupBlock: Sendable, Equatable {
	case markdown(String)
	case plain(String)
	case code(String, language: String?)
}

nonisolated public struct Markup: Sendable, Equatable {
	public var blocks: [MarkupBlock]

	public init(blocks: [MarkupBlock]) { self.blocks = blocks }

	/// `MarkupContent`, a `MarkedString` (string or `{language, value}`) or an array of them;
	/// nil when there is nothing to show.
	public init?(_ json: JSONValue?) {
		guard let json else { return nil }
		var blocks: [MarkupBlock] = []
		if let array = json.arrayValue {
			for item in array { blocks += Markup(item)?.blocks ?? [] }
		} else if let text = json.stringValue {
			blocks = Self.blocks(markdown: text) // a bare MarkedString is Markdown
		} else if let value = json["value"]?.stringValue {
			if let language = json["language"]?.stringValue {
				blocks = value.isEmpty ? [] : [.code(value, language: language)]
			} else if json["kind"]?.stringValue == "markdown" {
				blocks = Self.blocks(markdown: value)
			} else if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				blocks = [.plain(value)]
			}
		}
		guard !blocks.isEmpty else { return nil }
		self.blocks = blocks
	}

	/// Fenced code blocks (``` or ~~~, with a language after the fence) apart from the prose
	/// around them; empty prose and horizontal rules are left out.
	public static func blocks(markdown text: String) -> [MarkupBlock] {
		var blocks: [MarkupBlock] = []
		var prose: [Substring] = [], code: [Substring] = []
		var fence: (marker: Substring, language: String?)?
		func flushProse() {
			let s = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
			if !s.isEmpty { blocks.append(.markdown(s)) }
			prose = []
		}
		for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
			let trimmed = line.drop(while: { $0 == " " })
			if let open = fence {
				if trimmed.hasPrefix(open.marker), trimmed.drop(while: { $0 == open.marker.first }).allSatisfy(\.isWhitespace) {
					blocks.append(.code(code.joined(separator: "\n"), language: open.language))
					code = []
					fence = nil
				} else {
					code.append(line)
				}
			} else if let c = trimmed.first, c == "`" || c == "~" {
				let marker = trimmed.prefix(while: { $0 == c })
				guard marker.count >= 3 else { prose.append(line); continue }
				let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
				flushProse()
				fence = (marker, info.isEmpty ? nil : String(info.prefix(while: { !$0.isWhitespace })))
			} else if isRule(trimmed) {
				prose.append("") // a horizontal rule separates like a blank line
			} else {
				prose.append(line)
			}
		}
		if let open = fence { blocks.append(.code(code.joined(separator: "\n"), language: open.language)) }
		flushProse()
		return blocks
	}
}

/// `---`, `***` or `___` (spaces allowed between).
nonisolated private func isRule(_ line: Substring) -> Bool {
	let chars = line.filter { $0 != " " && $0 != "\t" }
	guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
	return chars.allSatisfy { $0 == c }
}

/// `textDocument/hover` (plan 3.7).
nonisolated public struct Hover: Sendable, Equatable {
	public var contents: Markup
	/// The symbol the hover is about, when the server says.
	public var range: LSPRange?

	public init?(_ json: JSONValue?) {
		guard let contents = Markup(json?["contents"]) else { return nil }
		self.contents = contents
		range = LSPRange(json?["range"])
	}
}

/// `textDocument/signatureHelp` (plan 3.7): the signatures of the call around the caret.
nonisolated public struct SignatureHelp: Sendable, Equatable {
	public struct Parameter: Sendable, Equatable {
		/// UTF-16 range in the signature's label.
		public var range: Range<Int>
		public var documentation: Markup?
	}

	public struct Signature: Sendable, Equatable {
		public var label: String
		public var documentation: Markup?
		public var parameters: [Parameter]
		/// Overrides the help's active parameter for this signature.
		public var activeParameter: Int?
	}

	public var signatures: [Signature]
	public var activeSignature: Int
	/// Index in the active signature's parameters; nil highlights none.
	public var activeParameter: Int?
	/// As the server sent it: goes back in the context of the next request.
	public var raw: JSONValue

	/// Nil for null or no signatures.
	public init?(_ json: JSONValue?) {
		guard let json, let list = json["signatures"]?.arrayValue else { return nil }
		signatures = list.compactMap(Self.signature)
		guard !signatures.isEmpty else { return nil }
		let index = json["activeSignature"]?.doubleValue.map { Int($0) } ?? 0
		activeSignature = signatures.indices.contains(index) ? index : 0
		let signature = signatures[activeSignature]
		// Omitted means the first parameter; out of range (past the last) means none.
		let param = signature.activeParameter ?? json["activeParameter"]?.doubleValue.map { Int($0) } ?? 0
		activeParameter = signature.parameters.indices.contains(param) ? param : nil
		raw = json
	}

	public var active: Signature { signatures[activeSignature] }

	private static func signature(_ json: JSONValue) -> Signature? {
		guard let label = json["label"]?.stringValue else { return nil }
		let utf16 = label.utf16
		var searchFrom = 0
		var parameters: [Parameter] = []
		for p in json["parameters"]?.arrayValue ?? [] {
			var range: Range<Int>?
			if let offsets = p["label"]?.arrayValue, offsets.count == 2,
			   let a = offsets[0].doubleValue.map({ Int($0) }), let b = offsets[1].doubleValue.map({ Int($0) }),
			   0 <= a, a <= b, b <= utf16.count {
				range = a..<b
			} else if let name = p["label"]?.stringValue, !name.isEmpty {
				// A string label: its first occurrence after the previous parameter.
				let ns = label as NSString
				let found = ns.range(of: name, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
				if found.location != NSNotFound { range = found.location..<(found.location + found.length) }
			}
			if let range { searchFrom = range.upperBound }
			parameters.append(Parameter(range: range ?? 0..<0, documentation: Markup(p["documentation"])))
		}
		let active = json["activeParameter"]?.doubleValue.map { Int($0) }
		return Signature(label: label, documentation: Markup(json["documentation"]), parameters: parameters, activeParameter: active)
	}
}

/// What the running server offers for signature help.
nonisolated public struct SignatureHelpSupport: Sendable, Equatable {
	/// Single-byte characters that open the help ("(", ",").
	public var triggerCharacters: Set<UInt8>
	/// Characters that ask again while it shows (")" closes a nested call).
	public var retriggerCharacters: Set<UInt8>

	init?(_ json: JSONValue?) {
		guard let json else { return nil }
		switch json {
		case .bool(true), .object: break
		default: return nil
		}
		func bytes(_ key: String) -> Set<UInt8> {
			Set((json[key]?.arrayValue ?? []).compactMap { $0.stringValue?.utf8.count == 1 ? $0.stringValue?.utf8.first : nil })
		}
		triggerCharacters = bytes("triggerCharacters")
		retriggerCharacters = bytes("retriggerCharacters")
	}
}

/// Why signature help is asked for.
nonisolated public enum SignatureHelpTrigger: Sendable, Equatable {
	case invoked
	case character(UInt8)
	/// The text or caret changed while the help shows.
	case contentChange
}

nonisolated extension LanguageServer {
	public var supportsHover: Bool {
		guard isRunning else { return false }
		switch capabilities["hoverProvider"] {
		case .bool(true), .object: return true
		default: return false
		}
	}

	public var signatureHelpSupport: SignatureHelpSupport? {
		isRunning ? SignatureHelpSupport(capabilities["signatureHelpProvider"]) : nil
	}

	/// Hover at `offset` of an open document (`rope` is its current text); nil when there is none.
	public func hover(uri: String, offset: Int, in rope: Rope) async throws -> Hover? {
		Hover(try await request("textDocument/hover", [
			"textDocument": ["uri": .string(uri)],
			"position": rope.position(ofByte: offset, encoding: positionEncoding).json,
		]))
	}

	/// Signature help at `offset`; `current` is the help shown now (a retrigger).
	public func signatureHelp(uri: String, offset: Int, in rope: Rope, trigger: SignatureHelpTrigger,
	                          current: SignatureHelp?) async throws -> SignatureHelp? {
		var context: [String: JSONValue] = ["isRetrigger": .bool(current != nil)]
		switch trigger {
		case .invoked: context["triggerKind"] = 1
		case .character(let c):
			context["triggerKind"] = 2
			context["triggerCharacter"] = .string(String(UnicodeScalar(c)))
		case .contentChange: context["triggerKind"] = 3
		}
		if let current { context["activeSignatureHelp"] = current.raw }
		return SignatureHelp(try await request("textDocument/signatureHelp", [
			"textDocument": ["uri": .string(uri)],
			"position": rope.position(ofByte: offset, encoding: positionEncoding).json,
			"context": .object(context),
		]))
	}
}
