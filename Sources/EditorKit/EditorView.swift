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
	let ctFont: CTFont
	let lineHeight: CGFloat
	let ascent: CGFloat
	let gutterWidth: CGFloat
	let textInset: CGFloat = 8
	private var markedText = ""
	private var preferredColumnX: CGFloat?

	private var layoutCache: [Int: LineLayout] = [:]
	private var numberCache: [Int: LineLayout] = [:]
	private let textAttributes: [NSAttributedString.Key: Any]

	/// Number of draw passes, drawn lines and time spent in draw(_:), for benchmarks.
	public private(set) var drawCount = 0
	public private(set) var drawnLines = 0
	public private(set) var drawSeconds = 0.0

	public init(text: String, font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
		rope = Rope(text)
		self.font = font
		ctFont = font as CTFont
		ascent = ceil(CTFontGetAscent(font))
		lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) + 3
		let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
		gutterWidth = ceil(digitWidth * 7) + 16
		textAttributes = [.font: font, .foregroundColor: NSColor.textColor]
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
		layoutCache.removeAll() // fallback CTLines carry their colour
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
		layoutCache.removeAll()
		updateSize()
		needsDisplay = true
	}

	// MARK: Drawing

	public override func draw(_ dirtyRect: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext else { return }
		drawCount += 1
		let drawStart = CACurrentMediaTime()
		defer { drawSeconds += CACurrentMediaTime() - drawStart }

		ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
		ctx.fill(dirtyRect)
		ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
		ctx.fill(CGRect(x: 0, y: dirtyRect.minY, width: gutterWidth, height: dirtyRect.height))

		let first = max(0, Int(dirtyRect.minY / lineHeight))
		let last = min(rope.lineCount - 1, Int(dirtyRect.maxY / lineHeight))
		let caretLine = rope.line(containing: caret)
		let textColor = NSColor.textColor.cgColor
		let numberColor = NSColor.tertiaryLabelColor.cgColor

		if first <= last {
			drawnLines += last - first + 1
			for line in first...last {
				let y = CGFloat(line) * lineHeight
				if line == caretLine {
					ctx.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.15).cgColor)
					ctx.fill(CGRect(x: gutterWidth, y: y, width: bounds.width - gutterWidth, height: lineHeight))
				}
				let number = numberLayout(line)
				ctx.setFillColor(numberColor)
				number.draw(in: ctx, font: ctFont, at: CGPoint(x: gutterWidth - 10 - number.width, y: y + ascent + 1))
				ctx.setFillColor(textColor)
				layout(line).draw(in: ctx, font: ctFont, at: CGPoint(x: gutterWidth + textInset, y: y + ascent + 1))
			}
		}
		drawCaret(ctx, line: caretLine)
		trimCaches(keepingAround: first...max(first, last))
	}

	/// Bounds memory: scrolling through a large file must not keep every line's layout.
	/// Evicted layouts are released on a background queue: freeing thousands of them
	/// on the main thread showed up as 2 ms frame spikes.
	private func trimCaches(keepingAround visible: ClosedRange<Int>) {
		let limit = 1500
		guard layoutCache.count > limit || numberCache.count > limit else { return }
		let caretLine = rope.line(containing: caret)
		let keep = (visible.lowerBound - 300)...(visible.upperBound + 300)
		let evicted = Evicted(layouts: layoutCache, numbers: numberCache)
		layoutCache = layoutCache.filter { keep.contains($0.key) || $0.key == caretLine }
		numberCache = numberCache.filter { keep.contains($0.key) }
		DispatchQueue.global(qos: .utility).async { evicted.release() }
	}

	private func drawCaret(_ ctx: CGContext, line: Int) {
		let x = caretX()
		let y = CGFloat(line) * lineHeight
		if !markedText.isEmpty {
			let marked = CTLineCreateWithAttributedString(NSAttributedString(string: markedText, attributes:
				textAttributes.merging([.underlineStyle: NSUnderlineStyle.single.rawValue]) { $1 }))
			ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
			ctx.fill(CGRect(x: x, y: y, width: CTLineGetTypographicBounds(marked, nil, nil, nil), height: lineHeight))
			ctx.setFillColor(NSColor.textColor.cgColor)
			LineLayout.withBaseline(ctx, CGPoint(x: x, y: y + ascent + 1)) { CTLineDraw(marked, ctx) }
		}
		ctx.setFillColor(NSColor.controlAccentColor.cgColor)
		ctx.fill(CGRect(x: x, y: y + 1, width: 2, height: lineHeight - 2))
	}

	private func layout(_ line: Int) -> LineLayout {
		if let cached = layoutCache[line] { return cached }
		let l = LineLayout(bytes: rope.bytes(in: rope.lineRange(line)), font: ctFont, attributes: textAttributes)
		layoutCache[line] = l
		return l
	}

	private func numberLayout(_ line: Int) -> LineLayout {
		if let cached = numberCache[line] { return cached }
		let l = LineLayout(bytes: Array(String(line + 1).utf8), font: ctFont, attributes: textAttributes)
		numberCache[line] = l
		return l
	}

	private func caretX() -> CGFloat {
		let line = rope.line(containing: caret)
		let column = rope.utf16Offset(ofByte: caret) - rope.utf16Offset(ofByte: rope.offset(ofLine: line))
		return gutterWidth + textInset + layout(line).x(atUnit: column)
	}

	private func lineRect(_ line: Int) -> NSRect {
		NSRect(x: 0, y: CGFloat(line) * lineHeight, width: bounds.width, height: lineHeight)
	}

	// MARK: Editing

	/// Replaces a byte range and repaints as little as possible.
	public func replace(_ range: Range<Int>, with text: String) {
		let firstLine = rope.line(containing: range.lowerBound)
		let removedNewlines = rope.line(containing: range.upperBound) - firstLine
		let oldLines = rope.lineCount
		let caretLineBefore = rope.line(containing: caret)
		rope.replace(range, with: text)
		caret = range.lowerBound + text.utf8.count

		if rope.lineCount == oldLines {
			layoutCache[firstLine] = nil
			setNeedsDisplay(lineRect(firstLine))
			if caretLineBefore != firstLine { setNeedsDisplay(lineRect(caretLineBefore)) }
		} else {
			shiftLayoutCache(from: firstLine, removed: removedNewlines, delta: rope.lineCount - oldLines)
			updateSize()
			let visible = visibleRect
			setNeedsDisplay(NSRect(x: 0, y: CGFloat(firstLine) * lineHeight, width: bounds.width,
			                       height: max(0, visible.maxY - CGFloat(firstLine) * lineHeight)))
		}
		scrollCaretVisible()
	}

	/// Keeps cached layouts of unchanged lines when lines are inserted or removed:
	/// lines before the edit stay, edited lines are dropped, lines after the edit move by `delta`.
	private func shiftLayoutCache(from line: Int, removed: Int, delta: Int) {
		var shifted: [Int: LineLayout] = [:]
		shifted.reserveCapacity(layoutCache.count)
		let firstUnchangedAfter = line + removed + 1 // old index of the first line below the edit
		for (index, l) in layoutCache {
			if index < line { shifted[index] = l }
			else if index >= firstUnchangedAfter { shifted[index + delta] = l }
		}
		layoutCache = shifted
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
		let rect = lineRect(line).insetBy(dx: 0, dy: -lineHeight)
		if !visibleRect.contains(rect) { scrollToVisible(rect) }
	}

	private func offset(atX x: CGFloat, line: Int) -> Int {
		let target = layout(line).unitIndex(atX: x - gutterWidth - textInset)
		let range = rope.lineRange(line)
		var units = 0
		var offset = range.lowerBound
		for scalar in rope.string(in: range).unicodeScalars {
			if units + scalar.utf16.count > target { break }
			units += scalar.utf16.count
			offset += scalar.utf8.count
		}
		return offset
	}

	// MARK: Input

	public override func keyDown(with event: NSEvent) {
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

/// Carries evicted cache entries to a background queue. CTLine is immutable and safe to
/// release from any thread; nothing else touches these values after eviction.
private final class Evicted: @unchecked Sendable {
	private var layouts: [Int: LineLayout]?
	private var numbers: [Int: LineLayout]?
	init(layouts: [Int: LineLayout], numbers: [Int: LineLayout]) {
		self.layouts = layouts
		self.numbers = numbers
	}
	func release() {
		layouts = nil
		numbers = nil
	}
}
