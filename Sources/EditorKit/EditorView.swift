import AppKit
import CoreText
import QuartzCore
import TextEngine

/// Phase-0 spike: a Core Text editor view that draws only visible lines from a rope.
/// Single caret, basic editing and marked text (dead keys, IME). Selections, undo,
/// styling and the layout cache rework come in phase 1.
@MainActor
public final class EditorView: NSView, @preconcurrency NSTextInputClient {
	public private(set) var rope: Rope
	public private(set) var caret = 0 // byte offset, always on a scalar boundary

	public let font: NSFont
	let lineHeight: CGFloat
	let ascent: CGFloat
	let gutterWidth: CGFloat
	let textInset: CGFloat = 8
	private var markedText = ""
	private var preferredColumnX: CGFloat?

	private var lineCache: [Int: CTLine] = [:]
	private var numberCache: [Int: CTLine] = [:]
	private var textAttributes: [NSAttributedString.Key: Any]
	private let numberAttributes: [NSAttributedString.Key: Any]

	/// Time from key event to the end of the next draw, in seconds (latency probe).
	public private(set) var latencySamples: [Double] = []
	private var pendingInputStart: CFTimeInterval?

	public init(text: String, font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
		rope = Rope(text)
		self.font = font
		ascent = ceil(CTFontGetAscent(font))
		lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) + 3
		let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
		gutterWidth = ceil(digitWidth * 7) + 16
		textAttributes = [.font: font, .foregroundColor: NSColor.textColor]
		numberAttributes = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
		super.init(frame: .zero)
		wantsLayer = true
		layerContentsRedrawPolicy = .onSetNeedsDisplay
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	public override var isFlipped: Bool { true }
	public override var acceptsFirstResponder: Bool { true }
	public override var isOpaque: Bool { true }

	public override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		lineCache.removeAll()
		numberCache.removeAll()
		needsDisplay = true
	}

	/// Height follows the line count; width follows the scroll view (no horizontal scroll yet).
	public func updateSize() {
		let width = enclosingScrollView?.contentSize.width ?? frame.width
		setFrameSize(NSSize(width: width, height: CGFloat(rope.lineCount) * lineHeight + lineHeight))
	}

	public func setText(_ text: String) {
		rope = Rope(text)
		caret = 0
		lineCache.removeAll()
		updateSize()
		needsDisplay = true
	}

	// MARK: Drawing

	/// Number of draw passes and drawn lines, for benchmarks.
	public private(set) var drawCount = 0
	public private(set) var drawnLines = 0

	public override func draw(_ dirtyRect: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext else { return }
		drawCount += 1
		NSColor.textBackgroundColor.setFill()
		dirtyRect.fill()
		NSColor.windowBackgroundColor.setFill()
		NSRect(x: 0, y: dirtyRect.minY, width: gutterWidth, height: dirtyRect.height).fill()

		ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
		let first = max(0, Int(dirtyRect.minY / lineHeight))
		let last = min(rope.lineCount - 1, Int(dirtyRect.maxY / lineHeight))
		let caretLine = rope.line(containing: caret)

		if first <= last {
			drawnLines += last - first + 1
			for line in first...last {
				let y = CGFloat(line) * lineHeight
				if line == caretLine {
					NSColor.selectedTextBackgroundColor.withAlphaComponent(0.15).setFill()
					NSRect(x: gutterWidth, y: y, width: bounds.width - gutterWidth, height: lineHeight).fill()
				}
				let number = numberLine(line)
				let numberWidth = CTLineGetTypographicBounds(number, nil, nil, nil)
				ctx.textPosition = CGPoint(x: gutterWidth - 10 - numberWidth, y: y + ascent + 1)
				CTLineDraw(number, ctx)
				ctx.textPosition = CGPoint(x: gutterWidth + textInset, y: y + ascent + 1)
				CTLineDraw(textLine(line), ctx)
			}
		}
		drawCaret(ctx, line: caretLine)

		if let start = pendingInputStart {
			latencySamples.append(CACurrentMediaTime() - start)
			pendingInputStart = nil
		}
	}

	private func drawCaret(_ ctx: CGContext, line: Int) {
		let x = caretX()
		let y = CGFloat(line) * lineHeight
		if !markedText.isEmpty {
			let marked = CTLineCreateWithAttributedString(NSAttributedString(string: markedText, attributes:
				textAttributes.merging([.underlineStyle: NSUnderlineStyle.single.rawValue]) { $1 }))
			NSColor.textBackgroundColor.setFill()
			NSRect(x: x, y: y, width: CTLineGetTypographicBounds(marked, nil, nil, nil), height: lineHeight).fill()
			ctx.textPosition = CGPoint(x: x, y: y + ascent + 1)
			CTLineDraw(marked, ctx)
		}
		NSColor.controlAccentColor.setFill()
		NSRect(x: x, y: y + 1, width: 2, height: lineHeight - 2).fill()
	}

	private func textLine(_ line: Int) -> CTLine {
		if let cached = lineCache[line] { return cached }
		var text = rope.string(in: rope.lineRange(line))
		if text.hasSuffix("\r") { text.removeLast() }
		let ct = CTLineCreateWithAttributedString(NSAttributedString(string: text.replacingOccurrences(of: "\t", with: "    "), attributes: textAttributes))
		lineCache[line] = ct
		return ct
	}

	private func numberLine(_ line: Int) -> CTLine {
		if let cached = numberCache[line] { return cached }
		let ct = CTLineCreateWithAttributedString(NSAttributedString(string: String(line + 1), attributes: numberAttributes))
		numberCache[line] = ct
		return ct
	}

	/// UTF-16 index of a byte offset within its line, matching the CTLine string (tabs expanded).
	private func utf16Column(_ offset: Int, line: Int) -> Int {
		let start = rope.offset(ofLine: line)
		let prefix = rope.string(in: start..<offset)
		return prefix.utf16.count + prefix.filter { $0 == "\t" }.count * 3
	}

	private func caretX() -> CGFloat {
		let line = rope.line(containing: caret)
		let column = utf16Column(caret, line: line)
		return gutterWidth + textInset + CTLineGetOffsetForStringIndex(textLine(line), column, nil)
	}

	private func lineRect(_ line: Int) -> NSRect {
		NSRect(x: 0, y: CGFloat(line) * lineHeight, width: bounds.width, height: lineHeight)
	}

	// MARK: Editing

	/// Replaces a byte range and repaints as little as possible.
	public func replace(_ range: Range<Int>, with text: String) {
		let firstLine = rope.line(containing: range.lowerBound)
		let oldLines = rope.lineCount
		let caretLineBefore = rope.line(containing: caret)
		rope.replace(range, with: text)
		caret = range.lowerBound + text.utf8.count

		if rope.lineCount == oldLines {
			lineCache[firstLine] = nil
			setNeedsDisplay(lineRect(firstLine))
			if caretLineBefore != firstLine { setNeedsDisplay(lineRect(caretLineBefore)) }
		} else {
			// Line numbers shift: drop cached text lines from the edit on and repaint below it.
			lineCache = lineCache.filter { $0.key < firstLine }
			updateSize()
			let visible = visibleRect
			setNeedsDisplay(NSRect(x: 0, y: CGFloat(firstLine) * lineHeight, width: bounds.width, height: max(0, visible.maxY - CGFloat(firstLine) * lineHeight)))
		}
		scrollCaretVisible()
	}

	func moveCaret(to offset: Int, keepColumn: Bool = false) {
		let oldLine = rope.line(containing: caret)
		caret = rope.scalarBoundary(atOrBefore: offset)
		if !keepColumn { preferredColumnX = nil }
		setNeedsDisplay(lineRect(oldLine))
		setNeedsDisplay(lineRect(rope.line(containing: caret)))
		scrollCaretVisible()
	}

	private func scrollCaretVisible() {
		let line = rope.line(containing: caret)
		scrollToVisible(lineRect(line).insetBy(dx: 0, dy: -lineHeight))
	}

	private func offset(atX x: CGFloat, line: Int) -> Int {
		let ct = textLine(line)
		let index = CTLineGetStringIndexForPosition(ct, CGPoint(x: x - gutterWidth - textInset, y: 0))
		let range = rope.lineRange(line)
		var units = 0
		var offset = range.lowerBound
		for scalar in rope.string(in: range).unicodeScalars {
			let width = scalar == "\t" ? 4 : scalar.utf16.count
			if units + width > max(index, 0) { break }
			units += width
			offset += scalar.utf8.count
		}
		return offset
	}

	// MARK: Input

	public override func keyDown(with event: NSEvent) {
		pendingInputStart = CACurrentMediaTime()
		if !(inputContext?.handleEvent(event) ?? false) {
			interpretKeyEvents([event])
		}
	}

	public override func mouseDown(with event: NSEvent) {
		let p = convert(event.locationInWindow, from: nil)
		let line = min(max(0, Int(p.y / lineHeight)), rope.lineCount - 1)
		moveCaret(to: offset(atX: p.x, line: line))
	}

	public override func doCommand(by selector: Selector) {
		switch selector {
		case #selector(deleteBackward(_:)):
			guard caret > 0 else { return }
			replace(rope.scalarBoundary(atOrBefore: caret - 1)..<caret, with: "")
		case #selector(deleteForward(_:)):
			guard caret < rope.byteCount else { return }
			var end = caret + 1
			while end < rope.byteCount && rope.byte(at: end) & 0xC0 == 0x80 { end += 1 }
			replace(caret..<end, with: "")
		case #selector(insertNewline(_:)): replace(caret..<caret, with: "\n")
		case #selector(insertTab(_:)): replace(caret..<caret, with: "\t")
		case #selector(moveLeft(_:)): if caret > 0 { moveCaret(to: caret - 1) }
		case #selector(moveRight(_:)):
			if caret < rope.byteCount {
				var o = caret + 1
				while o < rope.byteCount && rope.byte(at: o) & 0xC0 == 0x80 { o += 1 }
				moveCaret(to: o)
			}
		case #selector(moveUp(_:)): moveVertically(-1)
		case #selector(moveDown(_:)): moveVertically(1)
		case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)):
			moveCaret(to: rope.offset(ofLine: rope.line(containing: caret)))
		case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)):
			moveCaret(to: rope.lineRange(rope.line(containing: caret)).upperBound)
		case #selector(moveToBeginningOfDocument(_:)): moveCaret(to: 0)
		case #selector(moveToEndOfDocument(_:)): moveCaret(to: rope.byteCount)
		case #selector(pageDown(_:)), #selector(scrollPageDown(_:)): moveVertically(max(1, Int(visibleRect.height / lineHeight) - 1))
		case #selector(pageUp(_:)), #selector(scrollPageUp(_:)): moveVertically(-max(1, Int(visibleRect.height / lineHeight) - 1))
		default: break
		}
	}

	private func moveVertically(_ delta: Int) {
		let line = rope.line(containing: caret)
		let target = min(max(0, line + delta), rope.lineCount - 1)
		let x = preferredColumnX ?? caretX()
		preferredColumnX = x
		moveCaret(to: offset(atX: x, line: target), keepColumn: true)
	}

	// MARK: NSTextInputClient

	public func insertText(_ string: Any, replacementRange: NSRange) {
		let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
		markedText = ""
		replace(caret..<caret, with: text)
	}

	public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
		markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
		setNeedsDisplay(lineRect(rope.line(containing: caret)))
	}

	public func unmarkText() {
		markedText = ""
		setNeedsDisplay(lineRect(rope.line(containing: caret)))
	}

	public func selectedRange() -> NSRange {
		NSRange(location: rope.utf16Offset(ofByte: caret), length: 0)
	}

	public func markedRange() -> NSRange {
		markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
			: NSRange(location: rope.utf16Offset(ofByte: caret), length: markedText.utf16.count)
	}

	public func hasMarkedText() -> Bool { !markedText.isEmpty }

	public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

	public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

	public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
		let line = rope.line(containing: caret)
		let rect = NSRect(x: caretX(), y: CGFloat(line) * lineHeight, width: 1, height: lineHeight)
		return window?.convertToScreen(convert(rect, to: nil)) ?? rect
	}

	public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
