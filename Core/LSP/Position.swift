/// How `Position.character` counts: negotiated in `initialize`, UTF-16 when the server says nothing.
nonisolated public enum PositionEncoding: String, Sendable {
	case utf8 = "utf-8"
	case utf16 = "utf-16"
}

nonisolated public struct Position: Sendable, Hashable {
	public var line: Int
	public var character: Int

	public init(line: Int, character: Int) {
		self.line = line
		self.character = character
	}

	public init?(_ json: JSONValue?) {
		guard let line = json?["line"]?.doubleValue, let character = json?["character"]?.doubleValue else { return nil }
		self.init(line: Int(line), character: Int(character))
	}

	public var json: JSONValue { ["line": .number(Double(line)), "character": .number(Double(character))] }
}

nonisolated public struct LSPRange: Sendable, Hashable {
	public var start: Position
	public var end: Position

	public init(start: Position, end: Position) {
		self.start = start
		self.end = end
	}

	public init?(_ json: JSONValue?) {
		guard let start = Position(json?["start"]), let end = Position(json?["end"]) else { return nil }
		self.init(start: start, end: end)
	}

	public var json: JSONValue { ["start": start.json, "end": end.json] }
}

nonisolated extension Rope {
	/// LSP position of a byte offset.
	public func position(ofByte offset: Int, encoding: PositionEncoding) -> Position {
		let line = line(containing: offset)
		let start = self.offset(ofLine: line)
		switch encoding {
		case .utf8: return Position(line: line, character: offset - start)
		case .utf16: return Position(line: line, character: utf16Offset(ofByte: offset) - utf16Offset(ofByte: start))
		}
	}

	/// Byte offset of an LSP position. A character past the line end means the line end and a line
	/// past the last one the end of the text (as the spec asks); one inside a character snaps to its start.
	public func byteOffset(of position: Position, encoding: PositionEncoding) -> Int {
		guard position.line >= 0 else { return 0 }
		guard position.line < lineCount else { return byteCount }
		let range = lineRange(position.line)
		let character = max(position.character, 0)
		switch encoding {
		case .utf8:
			return scalarBoundary(atOrBefore: range.lowerBound + min(character, range.count))
		case .utf16:
			let base = utf16Offset(ofByte: range.lowerBound)
			return min(byteOffset(ofUTF16: base + character), range.upperBound)
		}
	}

	public func range(of range: LSPRange, encoding: PositionEncoding) -> Range<Int> {
		let a = byteOffset(of: range.start, encoding: encoding)
		let b = byteOffset(of: range.end, encoding: encoding)
		return min(a, b)..<max(a, b)
	}

	public func lspRange(_ range: Range<Int>, encoding: PositionEncoding) -> LSPRange {
		LSPRange(start: position(ofByte: range.lowerBound, encoding: encoding),
		         end: position(ofByte: range.upperBound, encoding: encoding))
	}
}
