/// One semantic token inside a line: bytes from the line start, indexes into the legend.
nonisolated public struct SemanticToken: Sendable, Equatable {
	public var start: Int
	public var length: Int
	public var type: Int
	/// Bit n set: modifier n of the legend.
	public var modifiers: Int

	public init(start: Int, length: Int, type: Int, modifiers: Int) {
		self.start = start
		self.length = length
		self.type = type
		self.modifiers = modifiers
	}
}

/// Token type and modifier names the server's token indexes refer to.
nonisolated public struct SemanticLegend: Sendable, Equatable {
	public var types: [String]
	public var modifiers: [String]

	public init(types: [String], modifiers: [String]) {
		self.types = types
		self.modifiers = modifiers
	}

	init?(_ json: JSONValue?) {
		guard let types = json?["tokenTypes"]?.arrayValue else { return nil }
		self.types = types.map { $0.stringValue ?? "" }
		modifiers = (json?["tokenModifiers"]?.arrayValue ?? []).map { $0.stringValue ?? "" }
	}

	/// Names of the modifier bits.
	public func modifierNames(_ bits: Int) -> [String] {
		modifiers.indices.filter { bits & (1 << $0) != 0 }.map { modifiers[$0] }
	}
}

nonisolated extension LanguageServer {
	/// The legend when the server sends whole-document semantic tokens.
	public var semanticLegend: SemanticLegend? {
		guard isRunning, let provider = capabilities["semanticTokensProvider"] else { return nil }
		switch provider["full"] {
		case .bool(true), .object: return SemanticLegend(provider["legend"])
		default: return nil
		}
	}

	/// Semantic tokens of the document by line (`rope.lineCount` arrays), positions in `rope`.
	public func semanticTokens(uri: String, in rope: Rope) async throws -> [[SemanticToken]] {
		let result = try await request("textDocument/semanticTokens/full", ["textDocument": ["uri": .string(uri)]])
		let data = (result["data"]?.arrayValue ?? []).map { $0.doubleValue.flatMap { Int(exactly: $0) } ?? -1 }
		return Self.decodeSemanticTokens(data, in: rope, encoding: positionEncoding)
	}

	/// Decodes the relative five-number groups (line delta, start delta, length, type,
	/// modifiers). Tokens past the text, past their line end or out of order are dropped.
	static func decodeSemanticTokens(_ data: [Int], in rope: Rope, encoding: PositionEncoding) -> [[SemanticToken]] {
		var lines = Array(repeating: [SemanticToken](), count: rope.lineCount)
		var line = 0, character = 0
		var bytes: [UInt8] = [], bytesLine = -1
		// Cursor in the current line: byte and character reached so far.
		var byte = 0, unit = 0
		func advance(to target: Int) {
			if encoding == .utf8 {
				byte = min(target, bytes.count)
				unit = target
				return
			}
			while unit < target && byte < bytes.count {
				let b = bytes[byte]
				byte += 1
				if b & 0xC0 == 0x80 { continue }
				unit += b >= 0xF0 ? 2 : 1
				// Skip the continuation bytes of this character.
				while byte < bytes.count && bytes[byte] & 0xC0 == 0x80 { byte += 1 }
			}
		}
		var i = 0
		while i + 4 < data.count {
			let dl = data[i], ds = data[i + 1], length = data[i + 2], type = data[i + 3], mods = data[i + 4]
			i += 5
			guard (0..<1 << 24).contains(dl), (0..<1 << 24).contains(ds), (0..<1 << 24).contains(length) else { break }
			line += dl
			character = dl == 0 ? character + ds : ds
			guard line < lines.count else { break }
			if line != bytesLine {
				bytes = rope.bytes(in: rope.lineRange(line))
				bytesLine = line
				byte = 0
				unit = 0
			}
			guard character >= unit else { continue }
			advance(to: character)
			let start = byte
			guard unit == character || encoding == .utf8, start < bytes.count else { continue }
			advance(to: character + length)
			if byte > start { lines[line].append(SemanticToken(start: start, length: byte - start, type: type, modifiers: mods)) }
		}
		return lines
	}
}
