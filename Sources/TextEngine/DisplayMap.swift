/// Maps document lines to display rows when folds hide some lines. Hidden ranges are merged
/// and sorted; lookups are binary searches. Soft wrapping (phase 1f) extends this map.
public struct DisplayMap: Sendable, Equatable {
	/// Hidden line ranges, sorted and disjoint (adjacent ranges stay separate).
	public private(set) var hidden: [ClosedRange<Int>] = []
	/// before[i] = hidden lines in hidden[0..<i].
	private var before: [Int] = [0]

	public init(hidden ranges: [ClosedRange<Int>] = []) {
		for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
			if let last = hidden.last, r.lowerBound <= last.upperBound {
				hidden[hidden.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
			} else {
				hidden.append(r)
			}
		}
		before = [0]
		for r in hidden { before.append(before.last! + r.count) }
	}

	public var isEmpty: Bool { hidden.isEmpty }
	public var hiddenCount: Int { before.last! }

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

	/// Display row of a line; a hidden line maps to the row of the line above its fold.
	public func row(of line: Int) -> Int {
		let i = index(of: line)
		if i < hidden.count && hidden[i].contains(line) { return hidden[i].lowerBound - 1 - before[i] }
		return line - before[i]
	}

	/// Document line shown at a display row.
	public func line(atRow row: Int) -> Int {
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
