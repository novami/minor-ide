import AppKit

/// What NSTextView gives for free: dragging selected text (move inside the editor, copy
/// to other editors and apps or with Option), dropping text from anywhere, and Look Up (force click,
/// ⌃⌘D, context menu).
extension EditorView: NSDraggingSource {
	/// A click on selected text that may become a drag; a click without moving places the caret.
	struct TextDragStart {
		var point: NSPoint
		var range: Range<Int>
	}

	/// The primary selection when a plain single click lands inside it.
	func textDragCandidate(at point: NSPoint, clicks: Int, modifiers: NSEvent.ModifierFlags) -> TextDragStart? {
		guard clicks == 1, modifiers.isDisjoint(with: [.shift, .option, .command, .control]) else { return nil }
		let range = selections.primary.range, offset = offset(at: point)
		guard !range.isEmpty, offset >= range.lowerBound, offset < range.upperBound else { return nil }
		return TextDragStart(point: point, range: range)
	}

	/// Starts the drag once the mouse moved a few points; true while the click is a drag candidate.
	func continueTextDrag(_ event: NSEvent) -> Bool {
		guard let start = textDragStart else { return false }
		let p = convert(event.locationInWindow, from: nil)
		guard hypot(p.x - start.point.x, p.y - start.point.y) >= 3 else { return true }
		textDragStart = nil
		let text = rope.string(in: start.range)
		let item = NSDraggingItem(pasteboardWriter: text as NSString)
		let image = dragImage(text)
		let origin = point(of: start.range.lowerBound, line: rope.line(containing: start.range.lowerBound))
		item.setDraggingFrame(NSRect(origin: origin, size: image.size), contents: image)
		textDragSource = start.range
		beginDraggingSession(with: [item], event: event, source: self)
		return true
	}

	/// Mouse up without a drag: the caret goes where the click was.
	func finishTextDragClick() -> Bool {
		guard let start = textDragStart else { return false }
		textDragStart = nil
		setSelections(SelectionSet(caret: offset(at: start.point)))
		return true
	}

	/// The first lines of the dragged text, as AppKit text views show it.
	private func dragImage(_ text: String) -> NSImage {
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(8)
		let string = NSAttributedString(string: lines.joined(separator: "\n"), attributes: textAttributes)
		let size = string.boundingRect(with: NSSize(width: min(bounds.width, 600), height: 1000), options: [.usesLineFragmentOrigin]).size
		return NSImage(size: NSSize(width: max(1, ceil(size.width)), height: max(1, ceil(size.height))), flipped: true) { rect in
			string.draw(with: rect, options: [.usesLineFragmentOrigin])
			return true
		}
	}

	public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
		context == .withinApplication && !isReadOnly ? [.copy, .move] : .copy
	}

	/// Text moves only inside the editor it came from (handled by the drop), else it is copied.
	public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
		textDragSource = nil
	}

	// MARK: Drop

	func registerForTextDrops() {
		registerForDraggedTypes([.string])
	}

	public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
		draggingUpdated(sender)
	}

	public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
		guard !isReadOnly else { return [] }
		let p = convert(sender.draggingLocation, from: nil)
		setDropOffset(offset(at: p))
		let visible = visibleRect
		if p.y < visible.minY + lineHeight || p.y > visible.maxY - lineHeight || p.x < visible.minX + 8 || p.x > visible.maxX - 8 {
			scrollToVisible(NSRect(x: p.x - 8, y: p.y - lineHeight, width: 16, height: lineHeight * 2))
		}
		return dropOperation(sender)
	}

	public override func draggingExited(_ sender: (any NSDraggingInfo)?) { setDropOffset(nil) }
	public override func draggingEnded(_ sender: any NSDraggingInfo) { setDropOffset(nil) }

	/// Moving inside this editor unless Option asks for a copy (the source mask then lacks move).
	private func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
		(sender.draggingSource as? EditorView) === self && sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
	}

	public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
		defer { setDropOffset(nil) }
		guard !isReadOnly, let text = sender.draggingPasteboard.string(forType: .string) else { return false }
		let offset = offset(at: convert(sender.draggingLocation, from: nil))
		let moving = dropOperation(sender) == .move ? textDragSource : nil
		dropText(text, at: offset, moving: moving)
		window?.makeFirstResponder(self)
		return true
	}

	/// Inserts dropped text (removing `moving` in the same undo step) and selects it.
	func dropText(_ text: String, at offset: Int, moving: Range<Int>?) {
		if let moving, offset >= moving.lowerBound, offset <= moving.upperBound {
			setSelections(SelectionSet([Selection(anchor: moving.lowerBound, head: moving.upperBound)]))
			return
		}
		var edits = [(offset..<offset, text)]
		if let moving { edits.append((moving, "")) }
		apply(ChangeSet(edits), kind: .other) { cs in
			let start = cs.map(offset, bias: .before)
			return SelectionSet([Selection(anchor: start, head: start + text.utf8.count)])
		}
	}

	private func setDropOffset(_ offset: Int?) {
		guard dropOffset != offset else { return }
		dropOffset = offset
		setNeedsCaretUpdate()
	}

	// MARK: Look Up

	/// Force click or three-finger tap: the word under the pointer.
	public override func quickLook(with event: NSEvent) {
		let offset = offset(at: convert(event.locationInWindow, from: nil))
		showDefinition(of: rope.wordRange(at: offset))
	}

	/// ⌃⌘D: the selection, or the word at the caret.
	public override func performKeyEquivalent(with event: NSEvent) -> Bool {
		if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command],
		   event.charactersIgnoringModifiers == "d" {
			lookUpSelection(nil)
			return true
		}
		return super.performKeyEquivalent(with: event)
	}

	@objc public func lookUpSelection(_ sender: Any?) {
		showDefinition(of: lookUpRange)
	}

	/// What Look Up shows: the primary selection, else the word at the caret.
	public var lookUpRange: Range<Int> {
		let s = selections.primary
		return s.isEmpty ? rope.wordRange(at: s.head) : s.range
	}

	private func showDefinition(of range: Range<Int>) {
		guard !range.isEmpty else { NSSound.beep(); return }
		let line = rope.line(containing: range.lowerBound)
		let end = min(range.upperBound, rope.lineRange(line).upperBound)
		let string = NSAttributedString(string: rope.string(in: range.lowerBound..<end), attributes: textAttributes)
		let p = point(of: range.lowerBound, line: line)
		showDefinition(for: string, at: NSPoint(x: p.x, y: p.y + ascent + 1))
	}
}
