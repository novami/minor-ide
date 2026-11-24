nonisolated extension Rope {
	/// Columns of the widest of `lines` (all lines by default): one per character, tabs to
	/// the next tab stop. Read in 64 KB chunks, so a large file is never copied whole.
	public func maxColumns(tabWidth: Int, lines: ClosedRange<Int>? = nil) -> Int {
		let tab = max(1, tabWidth)
		let start = lines.map { offset(ofLine: $0.lowerBound) } ?? 0
		let end = lines.map { lineRange(min($0.upperBound, lineCount - 1)).upperBound } ?? byteCount
		var widest = 0, col = 0
		var at = start
		while at < end {
			let chunk = bytes(in: at..<min(at + (1 << 16), end))
			for b in chunk {
				if b == 0x0A {
					widest = max(widest, col)
					col = 0
				} else if b == 0x09 {
					col = (col / tab + 1) * tab
				} else if b & 0xC0 != 0x80 && b != 0x0D {
					col += 1
				}
			}
			at += chunk.count
		}
		return max(widest, col)
	}
}
