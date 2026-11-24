import AppKit

extension Notification.Name {
	static let editorWrapDidChange = Notification.Name("MinorIDE.editorWrapDidChange")
}

/// Soft wrapping (phase 1f): one switch for all editors, wrapping at the file's
/// `max_line_length` (120 without it); files in simplified mode never wrap. A line takes
/// `display.rows(ofLine:)` rows; a row is a range of the line's UTF-16 units drawn shifted
/// left by the x of its first unit. An offset at a break belongs to the row it starts.
extension EditorView {
	/// Wrap long lines in every editor (settings.json "wrap_lines").
	public static var wrapsLines = false {
		didSet { if wrapsLines != oldValue { NotificationCenter.default.post(name: .editorWrapDidChange, object: nil) } }
	}

	public static let defaultWrapColumn = 120

	/// Column the editor wraps at, nil when not wrapping.
	public var wrapColumn: Int? {
		guard Self.wrapsLines, !document.isSimplified else { return nil }
		return format.maxLineLength ?? Self.defaultWrapColumn
	}

	func observeWrapSetting() {
		wrapObserver = NotificationCenter.default.addObserver(forName: .editorWrapDidChange, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.wrapSettingsChanged() }
		}
		if Self.wrapsLines { wrapSettingsChanged() }
	}

	/// Recomputes wrapping after the switch, the column, the tab width or the mode changed.
	func wrapSettingsChanged() {
		let column = wrapColumn
		if column == nil && wraps == nil { return }
		if column == wraps?.column && format.tabWidth == wraps?.tabWidth { return }
		wraps = column.map { WrapMap(rope: rope, column: $0, tabWidth: format.tabWidth) }
		rebuildDisplay()
		updateSize()
		needsDisplay = true
		gutter?.needsDisplay = true
		setNeedsCaretUpdate()
		scrollCaretVisible()
	}

	func breaks(ofLine line: Int) -> [Int] { wraps?.breaks(ofLine: line) ?? [] }

	/// UTF-16 unit of a byte offset within its line.
	func unit(of offset: Int, line: Int) -> Int {
		rope.utf16Offset(ofByte: offset) - rope.utf16Offset(ofByte: rope.offset(ofLine: line))
	}

	/// Row of a unit within its line: breaks at or before it.
	static func segment(ofUnit unit: Int, _ breaks: [Int]) -> Int {
		var lo = 0, hi = breaks.count
		while lo < hi {
			let mid = (lo + hi) / 2
			if breaks[mid] <= unit { lo = mid + 1 } else { hi = mid }
		}
		return lo
	}

	/// Units of a row of a line.
	func segmentUnits(line: Int, segment: Int, _ breaks: [Int]) -> Range<Int> {
		let start = segment == 0 ? 0 : breaks[segment - 1]
		let end = segment < breaks.count ? breaks[segment] : layout(line).unitCount
		return start..<max(start, end)
	}

	/// View position (x, row top) of a byte offset on its line.
	func point(of offset: Int, line: Int) -> CGPoint {
		let l = layout(line), u = unit(of: offset, line: line), b = breaks(ofLine: line)
		guard !b.isEmpty else { return CGPoint(x: textInset + l.x(atUnit: u), y: y(ofLine: line)) }
		let seg = Self.segment(ofUnit: u, b)
		let start = seg == 0 ? 0 : b[seg - 1]
		return CGPoint(x: textInset + l.x(atUnit: u) - l.x(atUnit: start), y: y(ofLine: line) + CGFloat(seg) * lineHeight)
	}

	/// Display row of a byte offset.
	func row(ofOffset offset: Int) -> Int {
		let line = rope.line(containing: offset)
		let b = breaks(ofLine: line)
		return display.row(of: line) + (b.isEmpty || display.isHidden(line) ? 0 : Self.segment(ofUnit: unit(of: offset, line: line), b))
	}

	/// Byte offset of a unit in a line.
	func offset(ofUnit unit: Int, line: Int) -> Int {
		rope.byteOffset(ofUTF16: rope.utf16Offset(ofByte: rope.offset(ofLine: line)) + unit)
	}

	/// Start and end of the row holding `offset` (⌘← and ⌘→). A row that wraps ends before
	/// its last character, since the offset at the break shows at the start of the next row.
	func rowBounds(of offset: Int) -> Range<Int> {
		let line = rope.line(containing: offset), range = rope.lineRange(line)
		let b = breaks(ofLine: line)
		guard !b.isEmpty else { return range }
		let seg = Self.segment(ofUnit: unit(of: offset, line: line), b)
		let start = seg == 0 ? range.lowerBound : self.offset(ofUnit: b[seg - 1], line: line)
		let end = seg < b.count ? rope.scalarBoundary(atOrBefore: self.offset(ofUnit: b[seg], line: line) - 1) : range.upperBound
		return start..<max(start, end)
	}

	/// Rows (line, row of the line) intersecting a vertical span, in order.
	func rows(inY minY: CGFloat, _ maxY: CGFloat) -> [(line: Int, segment: Int)] {
		let first = max(0, Int(minY / lineHeight)), last = min(rowCount - 1, Int(maxY / lineHeight))
		guard first <= last else { return [] }
		if display.isEmpty { return (first...last).map { ($0, 0) } }
		var rows: [(line: Int, segment: Int)] = []
		rows.reserveCapacity(last - first + 1)
		var p = display.position(atRow: first)
		for _ in first...last {
			rows.append(p)
			if p.segment + 1 < display.rows(ofLine: p.line) {
				p.segment += 1
			} else {
				p = (display.line(atRow: display.row(of: p.line) + display.rows(ofLine: p.line)), 0)
			}
		}
		return rows
	}

	/// Rectangles covering a byte range on the given lines, one per row; a range going on to
	/// the next line shows its line break as a short block past the end of the line.
	func rangeRects(_ range: Range<Int>, lines: ClosedRange<Int>) -> [CGRect] {
		let lowerLine = rope.line(containing: range.lowerBound), upperLine = rope.line(containing: range.upperBound)
		let from = max(lowerLine, lines.lowerBound), to = min(upperLine, lines.upperBound)
		guard from <= to else { return [] }
		var rects: [CGRect] = []
		for line in from...to where !display.isHidden(line) {
			let l = layout(line), b = breaks(ofLine: line)
			let lo = line == lowerLine ? unit(of: range.lowerBound, line: line) : 0
			let hi: Int? = line == upperLine ? unit(of: range.upperBound, line: line) : nil
			let top = y(ofLine: line)
			for seg in 0...b.count {
				let s = seg == 0 ? 0 : b[seg - 1], e = seg < b.count ? b[seg] : l.unitCount
				let lastRow = seg == b.count
				if let hi, hi < s || (hi == s && seg > 0) { break }
				if lo > e || (lo == e && !lastRow) { continue }
				let shift = l.x(atUnit: s)
				let x0 = textInset + l.x(atUnit: max(lo, s)) - shift
				var x1 = textInset + l.x(atUnit: min(hi ?? e, e)) - shift
				if hi == nil && lastRow { x1 += newlineWidth }
				rects.append(CGRect(x: x0, y: top + CGFloat(seg) * lineHeight, width: max(0, x1 - x0), height: lineHeight))
			}
		}
		return rects
	}
}
