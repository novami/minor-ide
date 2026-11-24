/// Lines that open the blocks around a line, by indentation like folding: each less indented
/// line above it, outermost first (the editor pins them at the top while scrolling).
nonisolated extension Rope {
	/// Header lines of the blocks enclosing `line`. A blank line takes the indentation of the
	/// next text line. Lines that only close or open a bracket (`) {`, `{` of a brace on its
	/// own line, `} else {`) are skipped, so the line with the name heads the block. Looks at
	/// most `maxScan` lines up.
	public func scopeHeaders(around line: Int, tabWidth: Int, maxScan: Int = 5000) -> [Int] {
		guard line >= 0, line < lineCount else { return [] }
		var limit = indentation(ofLine: line, tabWidth: tabWidth)
		if limit == nil, line + 1 < lineCount {
			limit = indentations(ofLines: (line + 1)..<min(lineCount, line + 100), tabWidth: tabWidth).lazy.compactMap { $0 }.first
		}
		guard var limit, limit > 0 else { return [] }
		var headers: [Int] = []
		// Indentation of blocks of lines from one read each, going up.
		var end = line
		let stop = max(0, line - maxScan)
		scan: while end > stop {
			let start = max(stop, end - 256)
			let indents = indentations(ofLines: start..<end, tabWidth: tabWidth)
			for header in (start..<end).reversed() {
				guard let indent = indents[header - start], indent < limit, !onlyBrackets(header) else { continue }
				headers.append(header)
				limit = indent
				if indent == 0 { break scan }
			}
			end = start
		}
		return headers.reversed()
	}

	/// True for a line starting with a closing bracket or holding just `{`.
	private func onlyBrackets(_ line: Int) -> Bool {
		let range = lineRange(line)
		let text = bytes(in: range.lowerBound..<min(range.upperBound, range.lowerBound + 256))
		guard let first = text.firstIndex(where: { $0 != 0x20 && $0 != 0x09 }) else { return false }
		switch text[first] {
		case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"): return true
		case UInt8(ascii: "{"): return text[(first + 1)...].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
		default: return false
		}
	}
}
