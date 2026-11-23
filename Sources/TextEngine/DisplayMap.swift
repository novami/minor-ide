/// Maps document lines to display rows: folds hide lines, soft wrapping gives a line extra
/// rows. Hidden ranges are merged and sorted; lookups are binary searches.
public struct DisplayMap: Sendable, Equatable {
	/// Hidden line ranges, sorted and disjoint (adjacent ranges stay separate).
	public private(set) var hidden: [ClosedRange<Int>] = []
	/// before[i] = hidden lines in hidden[0..<i].
	private var before: [Int] = [0]

	/// Visible wrapped lines: row of the line without wraps, its extra rows, and
	/// wrapBefore[i] = extra rows of wrapped lines before i.
	private var wrapLine: [Int] = []
	private var wrapRow: [Int] = []
	private var wrapExtra: [Int] = []
	private var wrapBefore: [Int] = [0]

	public init(hidden ranges: [ClosedRange<Int>] = [], wrapped: [(line: Int, extra: Int)] = []) {
		for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
			if let last = hidden.last, r.lowerBound <= last.upperBound {
				hidden[hidden.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
			} else {
				hidden.append(r)
			}
		}
		before = [0]
		for r in hidden { before.append((before.last ?? 0) + r.count) }
		for w in wrapped where w.extra > 0 && !isHidden(w.line) {
			wrapLine.append(w.line)
			wrapRow.append(foldRow(of: w.line))
			wrapExtra.append(w.extra)
			wrapBefore.append((wrapBefore.last ?? 0) + w.extra)
		}
	}

	public var isEmpty: Bool { hidden.isEmpty && wrapLine.isEmpty }
	public var hiddenCount: Int { before.last ?? 0 }
	/// Rows added by wrapping of visible lines.
	public var extraRows: Int { wrapBefore.last ?? 0 }

	public func rowCount(lineCount: Int) -> Int { lineCount - hiddenCount + extraRows }

	/// Rows a visible line takes (1 unless wrapped).
	public func rows(ofLine line: Int) -> Int {
		let i = wrapIndex(line)
		return i < wrapLine.count && wrapLine[i] == line ? 1 + wrapExtra[i] : 1
	}

	private func wrapIndex(_ line: Int) -> Int {
		var lo = 0, hi = wrapLine.count
		while lo < hi {
			let mid = (lo + hi) / 2
			if wrapLine[mid] < line { lo = mid + 1 } else { hi = mid }
		}
		return lo
	}

	/// Index of the first hidden range ending at or after `line`.
	private func index(of line: Int) -> Int {
		var lo = 0, hi = hidden.count
		while lo < hi {
			let mid = (lo + hi) / 2
			if hidden[mid].upperBound < line { lo = mid + 1 } else { hi = mid }
		}
		return lo
	}

	public func isHidden(_ line: Int) -> Bool {
		let i = index(of: line)
		return i < hidden.count && hidden[i].contains(line)
	}

	/// First display row of a line; a hidden line maps to the row of the line above its fold.
	public func row(of line: Int) -> Int {
		guard !wrapLine.isEmpty else { return foldRow(of: line) }
		let line = visibleLine(atOrBefore: line)
		return foldRow(of: line) + wrapBefore[wrapIndex(line)]
	}

	private func foldRow(of line: Int) -> Int {
		let i = index(of: line)
		if i < hidden.count && hidden[i].contains(line) { return hidden[i].lowerBound - 1 - before[i] }
		return line - before[i]
	}

	/// Document line shown at a display row.
	public func line(atRow row: Int) -> Int { position(atRow: row).line }

	/// Line and wrapped row of it (0 = first) shown at a display row.
	public func position(atRow row: Int) -> (line: Int, segment: Int) {
		guard !wrapLine.isEmpty else { return (foldLine(atRow: row), 0) }
		// Last wrapped line starting at or above the row.
		var lo = 0, hi = wrapLine.count
		while lo < hi {
			let mid = (lo + hi) / 2
			if wrapRow[mid] + wrapBefore[mid] <= row { lo = mid + 1 } else { hi = mid }
		}
		if lo > 0 {
			let i = lo - 1, start = wrapRow[i] + wrapBefore[i]
			if row <= start + wrapExtra[i] { return (wrapLine[i], row - start) }
		}
		return (foldLine(atRow: row - wrapBefore[lo]), 0)
	}

	private func foldLine(atRow row: Int) -> Int {
		// Ranges starting at or before the row (in display rows) push it down by their size.
		var lo = 0, hi = hidden.count
		while lo < hi {
			let mid = (lo + hi) / 2
			if hidden[mid].lowerBound - before[mid] <= row { lo = mid + 1 } else { hi = mid }
		}
		return row + before[lo]
	}

	/// Nearest visible line at or above `line`.
	public func visibleLine(atOrBefore line: Int) -> Int {
		let i = index(of: line)
		return i < hidden.count && hidden[i].contains(line) ? hidden[i].lowerBound - 1 : line
	}
}
