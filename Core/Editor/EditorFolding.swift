import AppKit

/// Folding by indentation (phase 1c; bracket and LSP folding come later). Rows are what the
/// view shows; a fold hides whole lines under its header line. A caret or selection that
/// lands in a fold (arrow keys, Find, undo) unfolds it.
extension EditorView {
	public var rowCount: Int { display.rowCount(lineCount: rope.lineCount) }

	/// Top of the first row of a line.
	public func y(ofLine line: Int) -> CGFloat { CGFloat(display.row(of: line)) * lineHeight }

	func line(atY y: CGFloat) -> Int { position(atY: y).line }

	/// Line and row of the line at a view y.
	func position(atY y: CGFloat) -> (line: Int, segment: Int) {
		display.position(atRow: min(max(0, Int(y / lineHeight)), rowCount - 1))
	}

	/// Visible lines with a row intersecting the span, in order.
	func lines(inY minY: CGFloat, _ maxY: CGFloat) -> [Int] {
		let first = max(0, Int(minY / lineHeight)), last = min(rowCount - 1, Int(maxY / lineHeight))
		guard first <= last else { return [] }
		if display.isEmpty { return Array(first...last) }
		var lines: [Int] = []
		for row in rows(inY: minY, maxY) where row.segment == 0 || lines.isEmpty { lines.append(row.line) }
		return lines
	}

	func rebuildDisplay() {
		display = DisplayMap(hidden: folds.map { rope.foldedLines($0) }, wrapped: wraps?.extraRows ?? [])
		foldedHeaders = Set(folds.map { rope.line(containing: $0.lowerBound) })
	}

	/// Replaces the folds and redraws everything that moved.
	func setFolds(_ new: [Range<Int>]) {
		let sorted = Array(Set(new)).sorted { $0.lowerBound != $1.lowerBound ? $0.lowerBound < $1.lowerBound : $0.upperBound < $1.upperBound }
		guard sorted != folds else { return }
		folds = sorted
		rebuildDisplay()
		updateSize()
		needsDisplay = true
		gutter?.needsDisplay = true
		setNeedsCaretUpdate()
	}

	/// Unfolds folds that hide a selection end; true when any was removed.
	@discardableResult
	func revealSelections() -> Bool {
		guard !folds.isEmpty else { return false }
		let ends = selections.all.flatMap { [$0.anchor, $0.head] }
		let kept = folds.filter { f in !ends.contains { $0 > f.lowerBound && $0 <= f.upperBound } }
		guard kept.count != folds.count else { return false }
		setFolds(kept)
		return true
	}

	/// Fold range headed by `line`, if the line heads a region.
	func foldRange(headedBy line: Int) -> Range<Int>? {
		rope.foldRegion(headedBy: line, tabWidth: format.tabWidth).map { rope.foldRange($0) }
	}

	/// Innermost unfolded region around `line`: its own, or that of a less indented line above.
	private func regionToFold(around line: Int) -> Range<Int>? {
		if let r = foldRange(headedBy: line), !folds.contains(r) { return r }
		var limit = rope.indentation(ofLine: line, tabWidth: format.tabWidth) ?? .max
		var header = line - 1
		while header >= 0 {
			if let indent = rope.indentation(ofLine: header, tabWidth: format.tabWidth), indent < limit {
				limit = indent
				if let r = foldRange(headedBy: header), rope.foldedLines(r).contains(line), !folds.contains(r) { return r }
			}
			header -= 1
		}
		return nil
	}

	/// ⌥⌘←: folds the region at each caret; again, the enclosing one.
	@objc public func fold(_ sender: Any?) {
		var new = folds
		for s in selections.all {
			if let r = regionToFold(around: rope.line(containing: s.head)) { new.append(r) }
		}
		guard new.count != folds.count else { return NSSound.beep() }
		setFolds(new)
		// Carets inside the new fold move to the end of its header line.
		setSelections(selections.map { s in
			guard let f = folds.first(where: { s.head > $0.lowerBound && s.head <= $0.upperBound }) else { return s }
			return Selection(caret: f.lowerBound)
		})
	}

	/// ⌥⌘→: unfolds folds headed by the caret lines or inside the selections.
	@objc public func unfold(_ sender: Any?) {
		let kept = folds.filter { f in
			!selections.all.contains { s in
				rope.line(containing: s.head) == rope.line(containing: f.lowerBound)
					|| (s.range.lowerBound <= f.lowerBound && f.upperBound <= s.range.upperBound && !s.isEmpty)
			}
		}
		guard kept.count != folds.count else { return NSSound.beep() }
		setFolds(kept)
	}

	/// ⌥⇧⌘←: folds every region that does not hold a caret.
	@objc public func foldAll(_ sender: Any?) {
		let ends = selections.all.flatMap { [$0.anchor, $0.head] }
		let all = rope.allFoldRegions(tabWidth: format.tabWidth).map { rope.foldRange($0.lines) }
		setFolds(folds + all.filter { r in !ends.contains { $0 > r.lowerBound && $0 <= r.upperBound } })
	}

	/// ⌥⇧⌘→
	@objc public func unfoldAll(_ sender: Any?) { setFolds([]) }

	/// Gutter click on a fold marker.
	public func toggleFold(atLine line: Int) {
		if foldedHeaders.contains(line) {
			setFolds(folds.filter { rope.line(containing: $0.lowerBound) != line })
		} else if let r = foldRange(headedBy: line) {
			setFolds(folds + [r])
			setSelections(selections.map { s in s.head > r.lowerBound && s.head <= r.upperBound ? Selection(caret: r.lowerBound) : s })
		}
	}

	/// Box after a folded header line; clicking it unfolds.
	func placeholderRect(_ line: Int) -> NSRect {
		let end = point(of: rope.lineRange(line).upperBound, line: line)
		return NSRect(x: end.x + 6, y: end.y + 2, width: lineHeight * 1.6, height: lineHeight - 4)
	}

	func drawFoldPlaceholders(_ ctx: CGContext, lines: [Int]) {
		for line in lines where foldedHeaders.contains(line) {
			let r = placeholderRect(line)
			ctx.setFillColor(NSColor.quaternaryLabelColor.cgColor)
			ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
			ctx.fillPath()
			// Three dots.
			ctx.setFillColor(NSColor.secondaryLabelColor.cgColor)
			let d: CGFloat = 2.5
			for i in -1...1 {
				ctx.fillEllipse(in: CGRect(x: r.midX + CGFloat(i) * d * 2 - d / 2, y: r.midY - d / 2, width: d, height: d))
			}
		}
	}

	/// Fold markers for the gutter: chevron right for folded, down for foldable lines. Each
	/// line's indentation is read once and both kinds are stroked as one path each.
	func drawFoldMarkers(_ ctx: CGContext, lines: [Int], centerX: CGFloat) {
		guard let first = lines.first, let last = lines.last else { return }
		// One read for the shown lines and a few below; folds can make the span long, then per line.
		let span = first..<min(rope.lineCount, last + 9)
		let known = span.count <= lines.count * 4 + 16 ? rope.indentations(ofLines: span, tabWidth: format.tabWidth) : []
		func indent(_ line: Int) -> Int? {
			if !known.isEmpty && span.contains(line) { return known[line - first] }
			return rope.indentation(ofLine: line, tabWidth: format.tabWidth)
		}
		func isHeader(_ line: Int) -> Bool {
			guard let i = indent(line) else { return false }
			var next = line + 1
			while next < rope.lineCount {
				if let j = indent(next) { return j > i }
				next += 1
			}
			return false
		}
		let open = CGMutablePath(), closed = CGMutablePath()
		let s: CGFloat = 3.5
		for line in lines {
			let cy = y(ofLine: line) + lineHeight / 2
			if foldedHeaders.contains(line) {
				closed.addLines(between: [CGPoint(x: centerX - s / 2, y: cy - s), CGPoint(x: centerX + s / 2, y: cy), CGPoint(x: centerX - s / 2, y: cy + s)])
			} else if isHeader(line) {
				open.addLines(between: [CGPoint(x: centerX - s, y: cy - s / 2), CGPoint(x: centerX, y: cy + s / 2), CGPoint(x: centerX + s, y: cy - s / 2)])
			}
		}
		ctx.setLineWidth(1.3)
		ctx.setLineCap(.round)
		ctx.setLineJoin(.round)
		for (path, color) in [(open, NSColor.tertiaryLabelColor), (closed, NSColor.secondaryLabelColor)] where !path.isEmpty {
			ctx.addPath(path)
			ctx.setStrokeColor(color.cgColor)
			ctx.strokePath()
		}
	}
}
