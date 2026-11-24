import Foundation

nonisolated extension LanguageServer {
	public var supportsFormatting: Bool {
		guard isRunning else { return false }
		switch capabilities["documentFormattingProvider"] {
		case .bool(true), .object: return true
		default: return false
		}
	}

	private var supportsRangeFormatting: Bool {
		switch capabilities["documentRangeFormattingProvider"] {
		case .bool(true), .object: return true
		default: return false
		}
	}

	/// Byte replacements that format the document, or only the lines of `range` when given.
	/// A server without range formatting formats the whole file and the edits outside those
	/// lines are dropped. Nil when the server sends overlapping edits.
	public func format(uri: String, range: Range<Int>? = nil, in rope: Rope, settings: FormatSettings) async throws -> [(Range<Int>, String)]? {
		let options: JSONValue = ["tabSize": .number(Double(settings.tabWidth)), "insertSpaces": .bool(settings.indentStyle == .space)]
		let lines = range.map { rope.lineSpan(of: $0) }
		let result: JSONValue
		if let lines, supportsRangeFormatting {
			result = try await request("textDocument/rangeFormatting", [
				"textDocument": ["uri": .string(uri)],
				"range": rope.lspRange(lines, encoding: positionEncoding).json,
				"options": options,
			])
		} else {
			result = try await request("textDocument/formatting", ["textDocument": ["uri": .string(uri)], "options": options])
		}
		let edits = (result.arrayValue ?? []).compactMap { TextEdit($0) }
		guard let list = rope.replacements(edits, encoding: positionEncoding) else { return nil }
		guard let lines else { return list }
		return list.filter { lines.lowerBound <= $0.0.lowerBound && $0.0.upperBound <= lines.upperBound }
	}
}

nonisolated extension Rope {
	/// The whole lines `range` touches, including the last line's line break.
	func lineSpan(of range: Range<Int>) -> Range<Int> {
		let first = line(containing: range.lowerBound)
		// A selection ending at the start of a line does not take that line.
		let endLine = range.isEmpty ? first : line(containing: max(range.lowerBound, range.upperBound - 1))
		return offset(ofLine: first)..<(endLine + 1 < lineCount ? offset(ofLine: endLine + 1) : byteCount)
	}
}
