/// Soft wrapping at a fixed column (phase 1f). Rows after the first start at break points
/// stored as UTF-16 units of the line, the unit the line layout uses. Rows break after the
/// last space in them when there is one, otherwise at the column; spaces may hang past it.
public struct WrapMap: Sendable, Equatable {
	public let column: Int
	public let tabWidth: Int
	/// Wrapped lines, sorted, and the units where their rows after the first start.
	public private(set) var lines: [Int] = []
	public private(set) var breaks: [[Int]] = []

	public init(column: Int, tabWidth: Int) {
		self.column = max(1, column)
		self.tabWidth = max(1, tabWidth)
	}

	public init(rope: Rope, column: Int, tabWidth: Int) {
		self.init(column: column, tabWidth: tabWidth)
		for line in 0..<rope.lineCount {
			let b = lineBreaks(rope, line)
			if !b.isEmpty { lines.append(line); breaks.append(b) }
		}
	}

	public var isEmpty: Bool { lines.isEmpty }

	/// Lines with more than one row and their extra rows (for `DisplayMap`).
	public var extraRows: [(line: Int, extra: Int)] { zip(lines, breaks).map { ($0, $1.count) } }

	private func index(of line: Int) -> Int {
		var lo = 0, hi = lines.count
		while lo < hi {
			let mid = (lo + hi) / 2
			if lines[mid] < line { lo = mid + 1 } else { hi = mid }
		}
		return lo
	}

	public func breaks(ofLine line: Int) -> [Int] {
		let i = index(of: line)
		return i < lines.count && lines[i] == line ? breaks[i] : []
	}

	/// After an edit replaced lines `first...oldLast` by `first...newLast`. True when the
	/// edited lines have a different number of rows than before.
	@discardableResult
	public mutating func update(rope: Rope, first: Int, oldLast: Int, newLast: Int) -> Bool {
		let lo = index(of: first), hi = index(of: oldLast + 1)
		let oldExtras = breaks[lo..<hi].map(\.count)
		var newLines: [Int] = [], newBreaks: [[Int]] = []
		for line in first...newLast {
			let b = lineBreaks(rope, line)
			if !b.isEmpty { newLines.append(line); newBreaks.append(b) }
		}
		let delta = newLast - oldLast
		if delta != 0 { for i in hi..<lines.count { lines[i] += delta } }
		lines.replaceSubrange(lo..<hi, with: newLines)
		breaks.replaceSubrange(lo..<hi, with: newBreaks)
		return oldExtras != newBreaks.map(\.count)
	}

	private func lineBreaks(_ rope: Rope, _ line: Int) -> [Int] {
		let range = rope.lineRange(line)
		// Fewer bytes than columns cannot wrap unless tabs widen them.
		if range.count <= column / tabWidth { return [] }
		return Self.breaks(rope.bytes(in: range), column: column, tabWidth: tabWidth)
	}

	/// Break units of one line (UTF-8 bytes without the newline).
	public static func breaks(_ bytes: [UInt8], column: Int, tabWidth: Int) -> [Int] {
		var n = bytes.count
		if n > 0 && bytes[n - 1] == 0x0D { n -= 1 }
		if n <= column / tabWidth { return [] }
		var result: [Int] = []
		var i = 0, unit = 0
		var col = 0           // column from the line start, tabs expanded as the layout does
		var rowStartCol = 0, rowStartUnit = 0
		var spaceUnit = -1, spaceCol = 0 // just after the last space or tab
		while i < n {
			let b = bytes[i]
			let len = b < 0x80 ? 1 : b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
			let space = b == 0x20 || b == 0x09
			var width = 1
			if b == 0x09 {
				width = (col / tabWidth + 1) * tabWidth - col
			} else if len > 1 && zeroWidth(bytes, i, len, n) {
				width = 0
			}
			if width > 0, !space, col - rowStartCol + width > column, col > rowStartCol {
				if spaceUnit > rowStartUnit {
					(rowStartUnit, rowStartCol) = (spaceUnit, spaceCol)
				} else {
					(rowStartUnit, rowStartCol) = (unit, col)
				}
				result.append(rowStartUnit)
			}
			col += width
			unit += len == 4 ? 2 : 1
			i += len
			if space { (spaceUnit, spaceCol) = (unit, col) }
		}
		return result
	}

	/// Combining marks, variation selectors and joiners stay with the character before them.
	private static func zeroWidth(_ bytes: [UInt8], _ i: Int, _ len: Int, _ n: Int) -> Bool {
		guard i + len <= n else { return false }
		var v = UInt32(bytes[i]) & (len == 2 ? 0x1F : len == 3 ? 0x0F : 0x07)
		for k in 1..<len { v = v << 6 | UInt32(bytes[i + k] & 0x3F) }
		return (0x0300...0x036F).contains(v) || (0x1AB0...0x1AFF).contains(v) || (0x20D0...0x20FF).contains(v)
			|| (0xFE00...0xFE0F).contains(v) || v == 0x200D || (0xE0100...0xE01EF).contains(v) || (0x1F3FB...0x1F3FF).contains(v)
	}
}
