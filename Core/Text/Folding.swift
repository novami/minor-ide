/// Folding by indentation: a line folds the lines below it that are indented deeper.
/// Blank lines inside a region belong to it, blank lines after its last line do not, so a
/// closing brace at the header's indentation stays visible.
nonisolated extension Rope {
	/// Visual indentation of a line (tabs to the next multiple of `tabWidth`), nil for a blank line.
	public func indentation(ofLine line: Int, tabWidth: Int) -> Int? {
		// Reads the leading whitespace in small chunks instead of copying the whole line.
		let range = lineRange(line)
		var column = 0
		var start = range.lowerBound
		while start < range.upperBound {
			let end = min(start + 64, range.upperBound)
			for byte in bytes(in: start..<end) {
				switch byte {
				case 0x20: column += 1
				case 0x09: column = (column / max(1, tabWidth) + 1) * max(1, tabWidth)
				case 0x0D: continue
				default: return column
				}
			}
			start = end
		}
		return nil
	}

	/// Indentation of consecutive lines from one read of the text (gutter fold markers).
	public func indentations(ofLines lines: Range<Int>, tabWidth: Int) -> [Int?] {
		guard !lines.isEmpty else { return [] }
		let tab = max(1, tabWidth)
		var result: [Int?] = []
		result.reserveCapacity(lines.count)
		var column = 0
		var blank = true, done = false
		for byte in bytes(in: offset(ofLine: lines.lowerBound)..<lineRange(lines.upperBound - 1).upperBound) {
			if byte == 0x0A {
				result.append(blank ? nil : column)
				column = 0
				blank = true
				done = false
				continue
			}
			guard !done else { continue }
			switch byte {
			case 0x20: column += 1
			case 0x09: column = (column / tab + 1) * tab
			case 0x0D: break
			default:
				blank = false
				done = true
			}
		}
		result.append(blank ? nil : column)
		return result
	}

	/// Lines a fold headed by `line` hides, nil when the next non-blank line is not deeper.
	public func foldRegion(headedBy line: Int, tabWidth: Int) -> ClosedRange<Int>? {
		guard let indent = indentation(ofLine: line, tabWidth: tabWidth) else { return nil }
		var last = line
		var next = line + 1
		while next < lineCount {
			if let i = indentation(ofLine: next, tabWidth: tabWidth) {
				guard i > indent else { break }
				last = next
			}
			next += 1
		}
		return last > line ? (line + 1)...last : nil
	}

	/// True when `line` heads a fold; looks only as far as the next non-blank line.
	public func isFoldHeader(_ line: Int, tabWidth: Int) -> Bool {
		guard let indent = indentation(ofLine: line, tabWidth: tabWidth) else { return false }
		var next = line + 1
		while next < lineCount {
			if let i = indentation(ofLine: next, tabWidth: tabWidth) { return i > indent }
			next += 1
		}
		return false
	}

	/// Every fold region in one pass, keyed by header line, nested ones included.
	public func allFoldRegions(tabWidth: Int) -> [(header: Int, lines: ClosedRange<Int>)] {
		var regions: [(header: Int, lines: ClosedRange<Int>)] = []
		var open: [(indent: Int, header: Int)] = []
		var lastNonBlank = -1
		func close(downTo indent: Int) {
			while let top = open.last, top.indent >= indent {
				open.removeLast()
				if lastNonBlank > top.header { regions.append((top.header, (top.header + 1)...lastNonBlank)) }
			}
		}
		for line in 0..<lineCount {
			guard let indent = indentation(ofLine: line, tabWidth: tabWidth) else { continue }
			close(downTo: indent)
			open.append((indent, line))
			lastNonBlank = line
		}
		close(downTo: 0)
		return regions.sorted { $0.header < $1.header }
	}

	/// Byte range a fold of `lines` covers: from the newline ending the header line to the end
	/// of the last hidden line. Edits touching it unfold it.
	public func foldRange(_ lines: ClosedRange<Int>) -> Range<Int> {
		lineRange(lines.lowerBound - 1).upperBound..<lineRange(lines.upperBound).upperBound
	}

	/// Hidden lines of a fold range.
	public func foldedLines(_ range: Range<Int>) -> ClosedRange<Int> {
		(line(containing: range.lowerBound) + 1)...max(line(containing: range.lowerBound) + 1, line(containing: range.upperBound))
	}
}
