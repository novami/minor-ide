import AppKit

/// Line and occurrence commands (phase 1c). Each command is one undo step.
extension EditorView {
	/// Line blocks the selections touch, in order; touching or adjacent blocks are merged.
	/// A selection ending at a line start does not include that line.
	func selectedLineBlocks() -> [ClosedRange<Int>] {
		var blocks: [ClosedRange<Int>] = []
		for s in selections.all {
			let a = rope.line(containing: s.range.lowerBound)
			var b = rope.line(containing: s.range.upperBound)
			if b > a && rope.offset(ofLine: b) == s.range.upperBound { b -= 1 }
			if let last = blocks.last, a <= last.upperBound + 1 {
				blocks[blocks.count - 1] = last.lowerBound...max(last.upperBound, b)
			} else {
				blocks.append(a...b)
			}
		}
		return blocks
	}

	private func blockRange(_ block: ClosedRange<Int>) -> Range<Int> {
		rope.offset(ofLine: block.lowerBound)..<rope.lineRange(block.upperBound).upperBound
	}

	/// Moves every selection inside a block by that block's delta. A selection ending at the
	/// start of the next line may land past the end when the block becomes the last line.
	private func shifted(_ blocks: [ClosedRange<Int>], growth: Int = 0, _ delta: (Int) -> Int) -> SelectionSet {
		let end = rope.byteCount + growth
		return selections.map { s in
			let line = rope.line(containing: s.range.lowerBound)
			guard let i = blocks.firstIndex(where: { $0.contains(line) }) else { return s }
			return Selection(anchor: min(s.anchor + delta(i), end), head: min(s.head + delta(i), end))
		}
	}

	/// ⇧⌘D: copies the selected lines below themselves; the selections move to the copy.
	@objc public func duplicateLines(_ sender: Any?) {
		let blocks = selectedLineBlocks()
		var edits: [(Range<Int>, String)] = []
		var deltas: [Int] = []
		var inserted = 0
		for block in blocks {
			let range = blockRange(block)
			let text = "\n" + rope.string(in: range)
			edits.append((range.upperBound..<range.upperBound, text))
			inserted += text.utf8.count
			deltas.append(inserted)
		}
		let after = shifted(blocks, growth: inserted) { deltas[$0] }
		apply(ChangeSet(edits), kind: .other) { _ in after }
	}

	/// ⌥⌘↑: swaps the selected lines with the line above.
	@objc public func moveLinesUp(_ sender: Any?) {
		let blocks = selectedLineBlocks()
		guard let first = blocks.first, first.lowerBound > 0 else { return }
		var edits: [(Range<Int>, String)] = []
		var deltas: [Int] = []
		for block in blocks {
			let above = rope.lineRange(block.lowerBound - 1)
			let text = rope.string(in: above)
			// Delete the line above with its newline, put it back after the block.
			edits.append((above.lowerBound..<rope.offset(ofLine: block.lowerBound), ""))
			let end = blockRange(block).upperBound
			edits.append((end..<end, "\n" + text))
			deltas.append(-(text.utf8.count + 1))
		}
		let after = shifted(blocks) { deltas[$0] }
		apply(ChangeSet(edits), kind: .other) { _ in after }
	}

	/// ⌥⌘↓: swaps the selected lines with the line below.
	@objc public func moveLinesDown(_ sender: Any?) {
		let blocks = selectedLineBlocks()
		guard let last = blocks.last, last.upperBound < rope.lineCount - 1 else { return }
		var edits: [(Range<Int>, String)] = []
		var deltas: [Int] = []
		for block in blocks {
			let range = blockRange(block)
			let below = rope.lineRange(block.upperBound + 1)
			let text = rope.string(in: below)
			// Put the line below before the block, delete it with the newline before it.
			edits.append((range.lowerBound..<range.lowerBound, text + "\n"))
			edits.append((range.upperBound..<below.upperBound, ""))
			deltas.append(text.utf8.count + 1)
		}
		let after = shifted(blocks) { deltas[$0] }
		apply(ChangeSet(edits), kind: .other) { _ in after }
	}

	/// Text the occurrence commands look for: the primary selection, or the word at the caret.
	private func occurrenceNeedle() -> (range: Range<Int>, bytes: [UInt8], wholeWord: Bool)? {
		let primary = selections.primary
		if !primary.isEmpty {
			let bytes = rope.bytes(in: primary.range)
			// A selected whole identifier matches only whole identifiers ("id" does not find "idx").
			let isWord = String(decoding: bytes, as: UTF8.self).unicodeScalars.allSatisfy { Rope.charClass($0) == .word }
			return (primary.range, bytes, isWord && rope.isWholeWord(primary.range))
		}
		let word = rope.wordRange(at: primary.head)
		guard let (s, _) = rope.scalar(at: word.lowerBound), Rope.charClass(s) == .word else { return nil }
		return (word, rope.bytes(in: word), true)
	}

	/// ⌃G: selects the word at the caret, then adds the next occurrence of the primary selection.
	@objc public func selectNextOccurrence(_ sender: Any?) {
		guard let needle = occurrenceNeedle() else { return }
		if selections.primary.isEmpty {
			setSelections(selections.replacingPrimary(Selection(anchor: needle.range.lowerBound, head: needle.range.upperBound)))
			return
		}
		let taken = Set(selections.all.map(\.range))
		var from = needle.range.upperBound
		for _ in 0...selections.count {
			guard let match = rope.nextRange(of: needle.bytes, from: from, wholeWord: needle.wholeWord) else { return }
			if !taken.contains(match) {
				setSelections(selections.adding(Selection(anchor: match.lowerBound, head: match.upperBound)))
				return
			}
			// Already selected (after wrapping): look past it.
			from = match.upperBound
		}
		NSSound.beep()
	}

	/// ⌃⌘G: selects every occurrence of the primary selection or of the word at the caret.
	@objc public func selectAllOccurrences(_ sender: Any?) {
		guard let needle = occurrenceNeedle() else { return }
		let matches = rope.ranges(of: needle.bytes, wholeWord: needle.wholeWord)
		guard let primary = matches.firstIndex(of: needle.range) else { return }
		setSelections(SelectionSet(matches.map { Selection(anchor: $0.lowerBound, head: $0.upperBound) }, primary: primary))
	}

	/// Selects `range` (byte offsets, clamped) and scrolls it to the middle (open a file at a
	/// line, search results).
	public func reveal(_ range: Range<Int>) {
		let lo = rope.scalarBoundary(atOrBefore: min(range.lowerBound, rope.byteCount))
		let hi = rope.scalarBoundary(atOrBefore: min(max(range.upperBound, lo), rope.byteCount))
		setSelections(SelectionSet([Selection(anchor: lo, head: hi)]))
		doCommand(by: #selector(NSResponder.centerSelectionInVisibleArea(_:)))
	}

	/// Caret at the start of `line` (0-based, clamped), scrolled to the middle.
	public func reveal(line: Int) {
		let start = rope.offset(ofLine: min(max(0, line), rope.lineCount - 1))
		reveal(start..<start)
	}

	/// Jump to Selection (⌘J) from the menu; the key binding route goes through doCommand.
	@objc public override func centerSelectionInVisibleArea(_ sender: Any?) {
		doCommand(by: #selector(NSResponder.centerSelectionInVisibleArea(_:)))
	}

	/// Rewrites the leading whitespace of every line to the current indent style: a tab
	/// counts as one level, `indentSize` spaces as one level, leftover spaces stay (alignment).
	@objc public func convertIndentation(_ sender: Any?) {
		let size = max(1, format.indentSize)
		var edits: [(Range<Int>, String)] = []
		for line in 0..<rope.lineCount {
			let start = rope.offset(ofLine: line)
			let leading = rope.bytes(in: start..<rope.lineRange(line).upperBound).prefix { $0 == 0x20 || $0 == 0x09 }
			guard !leading.isEmpty else { continue }
			var levels = 0, spaces = 0
			for byte in leading {
				if byte == 0x09 {
					levels += 1 + spaces / size
					spaces = 0
				} else {
					spaces += 1
				}
			}
			levels += spaces / size
			spaces %= size
			let indent = format.indentStyle == .tab
				? String(repeating: "\t", count: levels) + String(repeating: " ", count: spaces)
				: String(repeating: " ", count: levels * size + spaces)
			if Array(indent.utf8) != Array(leading) { edits.append((start..<(start + leading.count), indent)) }
		}
		guard !edits.isEmpty else { return }
		apply(ChangeSet(edits), kind: .other) { selections.mapped(through: $0) }
	}
}
