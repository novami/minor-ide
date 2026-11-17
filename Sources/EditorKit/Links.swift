import AppKit
import TextEngine

/// Jump to definition with the mouse (plan 3.5): ⌘+click or a middle click calls `onNavigate`
/// at the clicked offset; while ⌘ is held, the word under the mouse goes to `onLinkHover`, and the
/// handler underlines it (`linkRange`) once it knows the word leads somewhere.
extension EditorView {
	public override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if trackingAreas.isEmpty {
			addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
			                               owner: self, userInfo: nil))
		}
	}

	public override func mouseMoved(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		updateMouseWord(at: point, modifiers: event.modifierFlags)
		guard onLinkHover != nil else { return super.mouseMoved(with: event) }
		updateLinkHover(at: point, modifiers: event.modifierFlags)
	}

	public override func flagsChanged(with event: NSEvent) {
		super.flagsChanged(with: event)
		guard let window else { return }
		let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
		updateMouseWord(at: point, modifiers: event.modifierFlags)
		if onLinkHover != nil { updateLinkHover(at: point, modifiers: event.modifierFlags) }
	}

	public override func mouseExited(with event: NSEvent) {
		super.mouseExited(with: event)
		updateMouseWord(at: nil, modifiers: [])
		updateLinkHover(at: nil, modifiers: [])
	}

	func updateMouseWord(at point: NSPoint?, modifiers: NSEvent.ModifierFlags) {
		guard let onMouseWord else { return }
		let plain = modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty && NSEvent.pressedMouseButtons == 0
		let word = point.flatMap { plain && visibleRect.contains($0) ? linkWord(at: $0) : nil }
		guard word != mouseWord else { return }
		mouseWord = word
		onMouseWord(word)
	}

	public override func otherMouseDown(with event: NSEvent) {
		guard event.buttonNumber == 2, onNavigate?(offset(at: convert(event.locationInWindow, from: nil))) == true else {
			return super.otherMouseDown(with: event)
		}
	}

	/// ⌘ alone with one click: the click navigates instead of placing the caret.
	func navigatesOnClick(clicks: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
		clicks == 1 && onNavigate != nil && modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command
	}

	func updateLinkHover(at point: NSPoint?, modifiers: NSEvent.ModifierFlags) {
		guard let onLinkHover else { return }
		let command = modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command
		let word = point.flatMap { command && visibleRect.contains($0) ? linkWord(at: $0) : nil }
		guard word != hoveredWord else { return }
		hoveredWord = word
		if linkRange != word { linkRange = nil }
		onLinkHover(word)
	}

	/// Scrolling moves the text under a still mouse: the word under it is looked up again
	/// while ⌘ is held (called before drawing, which scrolling causes).
	func recheckLinkHover() {
		if mouseWord != nil, let window {
			updateMouseWord(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), modifiers: NSEvent.modifierFlags)
		}
		guard onLinkHover != nil, hoveredWord != nil || NSEvent.modifierFlags.contains(.command), let window else { return }
		updateLinkHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), modifiers: NSEvent.modifierFlags)
	}

	/// The word (letters, digits, _) under `point`; nil past the end of a line or over spaces.
	func linkWord(at point: NSPoint) -> Range<Int>? {
		let offset = offset(at: point)
		let range = rope.wordRange(at: offset)
		guard !range.isEmpty, let (s, _) = rope.scalar(at: range.lowerBound), Rope.charClass(s) == .word else { return nil }
		let line = rope.line(containing: range.lowerBound)
		guard rope.line(containing: range.upperBound) == line,
		      rangeRects(range, lines: line...line).contains(where: { $0.contains(point) }) else { return nil }
		return range
	}

	func linkChanged(_ old: Range<Int>?) {
		for range in [old, linkRange].compactMap({ $0 }) {
			let line = rope.line(containing: min(range.lowerBound, rope.byteCount))
			if line < rope.lineCount { setNeedsDisplay(lineRect(line)) }
		}
		if linkRange != nil {
			NSCursor.pointingHand.set()
		} else if let window, visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
			NSCursor.iBeam.set()
		}
	}

	/// The link underline in the link colour, just below the baseline.
	func drawLink(_ ctx: CGContext, lines: ClosedRange<Int>) {
		guard let linkRange, linkRange.upperBound <= rope.byteCount else { return }
		ctx.setFillColor(NSColor.linkColor.cgColor)
		for r in rangeRects(linkRange, lines: lines) {
			ctx.fill(CGRect(x: r.minX, y: r.minY + ascent + 2, width: r.width, height: 1))
		}
	}
}
