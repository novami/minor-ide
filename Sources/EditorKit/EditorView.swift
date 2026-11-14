import AppKit
import CoreText
import QuartzCore
import MinorCore
import TextEngine

/// Core Text editor view that draws only visible lines from a rope. Multiple selections,
/// basic editing and marked text (dead keys, IME). Undo, styling and the layout cache
/// rework come later in phase 1.
@MainActor
public final class EditorView: NSView, @preconcurrency NSTextInputClient {
	public private(set) var rope: Rope
	/// Byte offsets, always on scalar boundaries.
	public private(set) var selections = SelectionSet()
	/// Head of the primary selection.
	public var caret: Int { selections.primary.head }

	/// Called after every text change (dirty tracking).
	public var onChange: (() -> Void)?

	/// Indentation and tab display for this document. The buffer always uses "\n";
	/// line endings and charset apply when saving.
	public var format = FormatSettings() {
		didSet {
			guard format.tabWidth != oldValue.tabWidth else { return }
			layoutCache.removeAll()
			needsDisplay = true
		}
	}

	public let font: NSFont
	let ctFont: CTFont
	let lineHeight: CGFloat
	let ascent: CGFloat
	let gutterWidth: CGFloat
	let textInset: CGFloat = 8
	private let newlineWidth: CGFloat
	private var markedText = ""
	/// Goal x of each selection for up/down moves, in selection order.
	private var goalXs: [CGFloat]?

	private var layoutCache = LayoutCache()
	private var numberCache = LayoutCache()
	private let ascii: AsciiGlyphs
	private var batchGlyphs: [CGGlyph] = []
	private var batchPositions: [CGPoint] = []
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
		newlineWidth = ceil(digitWidth / 2)
		textAttributes = [.font: font, .foregroundColor: NSColor.textColor]
		ascii = AsciiGlyphs(font: font as CTFont)
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
		selections = SelectionSet()
		goalXs = nil
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
		// Offscreen caching can pass an unbounded rect.
		let dirtyRect = dirtyRect.intersection(bounds)
		guard !dirtyRect.isEmpty else { return }

		ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
		ctx.fill(dirtyRect)
		ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
		ctx.fill(CGRect(x: 0, y: dirtyRect.minY, width: gutterWidth, height: dirtyRect.height))

		let first = max(0, Int(dirtyRect.minY / lineHeight))
		let last = min(rope.lineCount - 1, Int(dirtyRect.maxY / lineHeight))
		let textColor = NSColor.textColor.cgColor
		let numberColor = NSColor.tertiaryLabelColor.cgColor
		let visible = selections.all.filter {
			rope.line(containing: $0.range.upperBound) >= first && rope.line(containing: $0.range.lowerBound) <= last
		}

		if first <= last {
			drawnLines += last - first + 1
			drawSelectionBackground(ctx, visible, lines: first...last)
			// Fast-path lines are batched into one glyph draw per colour; CTLine fallbacks draw alone.
			drawBatch(ctx, color: numberColor, lines: first...last) { line in
				let n = numberLayout(line)
				return (n, gutterWidth - 10 - n.width)
			}
			drawBatch(ctx, color: textColor, lines: first...last) { line in (layout(line), gutterWidth + textInset) }
		}
		for s in visible { drawCaret(ctx, at: s.head, marked: s == selections.primary) }
		let keep = (first - 300)...(max(first, last) + 300)
		layoutCache.trim(keep: keep, limit: 1500) // bounds memory when scrolling through large files
		numberCache.trim(keep: keep, limit: 1500)
	}

	/// Current-line highlight under carets, then selected ranges.
	private func drawSelectionBackground(_ ctx: CGContext, _ visible: [Selection], lines: ClosedRange<Int>) {
		ctx.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.15).cgColor)
		var lastHighlighted = -1
		for s in visible where s.isEmpty {
			let line = rope.line(containing: s.head)
			guard line != lastHighlighted, lines.contains(line) else { continue }
			lastHighlighted = line
			ctx.fill(CGRect(x: gutterWidth, y: CGFloat(line) * lineHeight, width: bounds.width - gutterWidth, height: lineHeight))
		}
		let color = window?.firstResponder === self ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
		ctx.setFillColor(color.cgColor)
		let textStart = gutterWidth + textInset
		for s in visible where !s.isEmpty {
			let lowerLine = rope.line(containing: s.range.lowerBound)
			let upperLine = rope.line(containing: s.range.upperBound)
			for line in max(lowerLine, lines.lowerBound)...min(upperLine, lines.upperBound) {
				let x0 = line == lowerLine ? x(of: s.range.lowerBound, line: line) : textStart
				// A selected line break shows as a short block past the line end.
				let x1 = line == upperLine ? x(of: s.range.upperBound, line: line) : textStart + layout(line).width + newlineWidth
				ctx.fill(CGRect(x: x0, y: CGFloat(line) * lineHeight, width: max(0, x1 - x0), height: lineHeight))
			}
		}
	}

	private func drawBatch(_ ctx: CGContext, color: CGColor, lines: ClosedRange<Int>, _ layoutAt: (Int) -> (LineLayout, CGFloat)) {
		ctx.setFillColor(color)
		batchGlyphs.removeAll(keepingCapacity: true)
		batchPositions.removeAll(keepingCapacity: true)
		for line in lines {
			let (l, x) = layoutAt(line)
			let baseline = CGFloat(line) * lineHeight + ascent + 1
			if l.ctLine != nil {
				l.draw(in: ctx, font: ctFont, at: CGPoint(x: x, y: baseline))
				continue
			}
			batchGlyphs.append(contentsOf: l.glyphs)
			// The batch is drawn with the CTM flipped around y = 0, so baselines are negated.
			for p in l.positions { batchPositions.append(CGPoint(x: x + p.x, y: -baseline)) }
		}
		guard !batchGlyphs.isEmpty else { return }
		LineLayout.withBaseline(ctx, .zero) {
			CTFontDrawGlyphs(ctFont, batchGlyphs, batchPositions, batchGlyphs.count, ctx)
		}
	}

	private func drawCaret(_ ctx: CGContext, at offset: Int, marked: Bool) {
		let line = rope.line(containing: offset)
		let cx = x(of: offset, line: line)
		let y = CGFloat(line) * lineHeight
		if marked && !markedText.isEmpty {
			let marked = CTLineCreateWithAttributedString(NSAttributedString(string: markedText, attributes:
				textAttributes.merging([.underlineStyle: NSUnderlineStyle.single.rawValue]) { $1 }))
			ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
			ctx.fill(CGRect(x: cx, y: y, width: CTLineGetTypographicBounds(marked, nil, nil, nil), height: lineHeight))
			ctx.setFillColor(NSColor.textColor.cgColor)
			LineLayout.withBaseline(ctx, CGPoint(x: cx, y: y + ascent + 1)) { CTLineDraw(marked, ctx) }
		}
		ctx.setFillColor(NSColor.controlAccentColor.cgColor)
		ctx.fill(CGRect(x: cx, y: y + 1, width: 2, height: lineHeight - 2))
	}

	private func layout(_ line: Int) -> LineLayout {
		if let cached = layoutCache[line] { return cached }
		let l = LineLayout(bytes: rope.bytes(in: rope.lineRange(line)), font: ctFont, ascii: ascii, tabWidth: format.tabWidth, attributes: textAttributes)
		layoutCache[line] = l
		return l
	}

	private func numberLayout(_ line: Int) -> LineLayout {
		if let cached = numberCache[line] { return cached }
		let l = LineLayout(bytes: Array(String(line + 1).utf8), font: ctFont, ascii: ascii, tabWidth: format.tabWidth, attributes: textAttributes)
		numberCache[line] = l
		return l
	}

	/// View x of a byte offset on its line.
	private func x(of offset: Int, line: Int) -> CGFloat {
		let column = rope.utf16Offset(ofByte: offset) - rope.utf16Offset(ofByte: rope.offset(ofLine: line))
		return gutterWidth + textInset + layout(line).x(atUnit: column)
	}

	private func x(of offset: Int) -> CGFloat { x(of: offset, line: rope.line(containing: offset)) }

	private func lineRect(_ line: Int) -> NSRect {
		NSRect(x: 0, y: CGFloat(line) * lineHeight, width: bounds.width, height: lineHeight)
	}

	private func invalidate(_ set: SelectionSet) {
		for s in set.all {
			let a = rope.line(containing: s.range.lowerBound)
			let b = s.isEmpty ? a : rope.line(containing: s.range.upperBound)
			setNeedsDisplay(NSRect(x: 0, y: CGFloat(a) * lineHeight, width: bounds.width, height: CGFloat(b - a + 1) * lineHeight))
		}
	}

	// MARK: Selections

	public func setSelections(_ new: SelectionSet) { setSelections(new, keepGoal: false) }

	private func setSelections(_ new: SelectionSet, keepGoal: Bool) {
		if !keepGoal { goalXs = nil }
		guard new != selections else { return }
		invalidate(selections)
		selections = new
		invalidate(selections)
		scrollCaretVisible()
	}

	func moveCaret(to offset: Int) {
		setSelections(SelectionSet(caret: rope.scalarBoundary(atOrBefore: offset)))
	}

	/// Moves every head; without `extend` each selection collapses to a caret there.
	private func move(extend: Bool, _ target: (Selection) -> Int) {
		setSelections(selections.map { s in
			let head = rope.scalarBoundary(atOrBefore: min(max(0, target(s)), rope.byteCount))
			return extend ? Selection(anchor: s.anchor, head: head) : Selection(caret: head)
		})
	}

	private func previous(_ offset: Int) -> Int { offset > 0 ? rope.scalarBoundary(atOrBefore: offset - 1) : 0 }

	private func next(_ offset: Int) -> Int {
		guard offset < rope.byteCount else { return offset }
		var o = offset + 1
		while o < rope.byteCount && rope.byte(at: o) & 0xC0 == 0x80 { o += 1 }
		return o
	}

	private func moveVertically(_ delta: Int, extend: Bool) {
		let goals = goalXs.flatMap { $0.count == selections.count ? $0 : nil } ?? selections.all.map { s in
			x(of: extend || s.isEmpty ? s.head : (delta < 0 ? s.range.lowerBound : s.range.upperBound))
		}
		let moved = SelectionSet(zip(selections.all, goals).map { s, goal in
			let from = extend || s.isEmpty ? s.head : (delta < 0 ? s.range.lowerBound : s.range.upperBound)
			let target = min(max(0, rope.line(containing: from) + delta), rope.lineCount - 1)
			let head = offset(atX: goal, line: target)
			return extend ? Selection(anchor: s.anchor, head: head) : Selection(caret: head)
		}, primary: selections.primaryIndex)
		setSelections(moved, keepGoal: true)
		goalXs = moved.count == goals.count ? goals : nil
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

	private func offset(at point: NSPoint) -> Int {
		let line = min(max(0, Int(point.y / lineHeight)), rope.lineCount - 1)
		return offset(atX: point.x, line: line)
	}

	// MARK: Editing

	/// Replaces a byte range, leaving a single caret after the new text.
	public func replace(_ range: Range<Int>, with text: String) {
		apply(ChangeSet([(range, text)])) { cs in SelectionSet(caret: cs.map(range.upperBound, bias: .after)) }
	}

	/// Replaces every selection with its own text; carets end after the new text.
	private func replaceSelections(_ text: (Selection) -> String) {
		replaceSelections { s in (s.range, text(s)) }
	}

	private func replaceSelections(_ edit: (Selection) -> (Range<Int>, String)) {
		let edits = selections.all.map(edit)
		apply(ChangeSet(edits)) { cs in
			SelectionSet(edits.map { Selection(caret: cs.map($0.0.upperBound, bias: .after)) }, primary: selections.primaryIndex)
		}
	}

	/// Applies the edit, sets the selections it produces and repaints as little as possible.
	private func apply(_ changes: ChangeSet, selectionsAfter: (ChangeSet) -> SelectionSet) {
		guard !changes.isEmpty, let firstChange = changes.changes.first, let lastChange = changes.changes.last else { return }
		let firstLine = rope.line(containing: firstChange.range.lowerBound)
		let lastLine = rope.line(containing: lastChange.range.upperBound)
		let oldLines = rope.lineCount
		// Without line breaks removed or inserted, every line keeps its number.
		let sameLines = changes.changes.allSatisfy { c in
			!c.text.contains(0x0A) && rope.line(containing: c.range.lowerBound) == rope.line(containing: c.range.upperBound)
		}
		let editedLines = sameLines ? changes.changes.map { rope.line(containing: $0.range.lowerBound) } : []
		invalidate(selections)

		changes.apply(to: &rope)
		selections = selectionsAfter(changes)
		goalXs = nil
		onChange?()

		if sameLines {
			for line in editedLines {
				layoutCache[line] = nil
				setNeedsDisplay(lineRect(line))
			}
		} else {
			layoutCache.shift(from: firstLine, removed: lastLine - firstLine, delta: rope.lineCount - oldLines)
			if rope.lineCount != oldLines { updateSize() }
			let visible = visibleRect
			setNeedsDisplay(NSRect(x: 0, y: CGFloat(firstLine) * lineHeight, width: bounds.width,
			                       height: max(0, visible.maxY - CGFloat(firstLine) * lineHeight)))
		}
		invalidate(selections)
		scrollCaretVisible()
	}

	// MARK: Input

	public override func keyDown(with event: NSEvent) {
		if !(inputContext?.handleEvent(event) ?? false) {
			interpretKeyEvents([event])
		}
	}

	public override func mouseDown(with event: NSEvent) {
		let offset = offset(at: convert(event.locationInWindow, from: nil))
		if event.modifierFlags.contains(.shift) {
			setSelections(selections.replacingPrimary(Selection(anchor: selections.primary.anchor, head: offset)))
		} else if event.modifierFlags.contains(.option) {
			setSelections(selections.adding(Selection(caret: offset)))
		} else {
			setSelections(SelectionSet(caret: offset))
		}
	}

	public override func mouseDragged(with event: NSEvent) {
		autoscroll(with: event)
		let offset = offset(at: convert(event.locationInWindow, from: nil))
		setSelections(selections.replacingPrimary(Selection(anchor: selections.primary.anchor, head: offset)))
	}

	public override func becomeFirstResponder() -> Bool {
		invalidate(selections) // selection colour follows focus
		return super.becomeFirstResponder()
	}

	public override func resignFirstResponder() -> Bool {
		invalidate(selections)
		return super.resignFirstResponder()
	}

	public override func doCommand(by selector: Selector) {
		var page: Int { max(1, Int(min(visibleRect.height, 1e6) / lineHeight) - 1) }
		let lineStart = { (o: Int) in self.rope.offset(ofLine: self.rope.line(containing: o)) }
		let lineEnd = { (o: Int) in self.rope.lineRange(self.rope.line(containing: o)).upperBound }
		switch selector {
		case #selector(deleteBackward(_:)):
			replaceSelections { s in (s.isEmpty ? previous(s.head)..<s.head : s.range, "") }
		case #selector(deleteForward(_:)):
			replaceSelections { s in (s.isEmpty ? s.head..<next(s.head) : s.range, "") }
		case #selector(insertNewline(_:)):
			// Keep the current line's indentation (up to the caret).
			replaceSelections { s in
				let start = lineStart(s.range.lowerBound)
				let indent = rope.bytes(in: start..<s.range.lowerBound).prefix { $0 == 0x20 || $0 == 0x09 }
				return "\n" + String(decoding: indent, as: UTF8.self)
			}
		case #selector(insertTab(_:)):
			replaceSelections { s in
				format.indentStyle == .tab ? "\t"
					: String(repeating: " ", count: format.indentSize - visualColumn(s.range.lowerBound) % format.indentSize)
			}
		case #selector(insertBacktab(_:)): outdentLines()
		case #selector(cancelOperation(_:)): setSelections(SelectionSet([selections.primary]))

		case #selector(moveLeft(_:)): move(extend: false) { $0.isEmpty ? previous($0.head) : $0.range.lowerBound }
		case #selector(moveRight(_:)): move(extend: false) { $0.isEmpty ? next($0.head) : $0.range.upperBound }
		case #selector(moveLeftAndModifySelection(_:)): move(extend: true) { previous($0.head) }
		case #selector(moveRightAndModifySelection(_:)): move(extend: true) { next($0.head) }
		case #selector(moveUp(_:)): moveVertically(-1, extend: false)
		case #selector(moveDown(_:)): moveVertically(1, extend: false)
		case #selector(moveUpAndModifySelection(_:)): moveVertically(-1, extend: true)
		case #selector(moveDownAndModifySelection(_:)): moveVertically(1, extend: true)
		case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)):
			move(extend: false) { lineStart($0.head) }
		case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)):
			move(extend: false) { lineEnd($0.head) }
		case #selector(moveToBeginningOfLineAndModifySelection(_:)), #selector(moveToLeftEndOfLineAndModifySelection(_:)):
			move(extend: true) { lineStart($0.head) }
		case #selector(moveToEndOfLineAndModifySelection(_:)), #selector(moveToRightEndOfLineAndModifySelection(_:)):
			move(extend: true) { lineEnd($0.head) }
		case #selector(moveToBeginningOfDocument(_:)): setSelections(SelectionSet(caret: 0))
		case #selector(moveToEndOfDocument(_:)): setSelections(SelectionSet(caret: rope.byteCount))
		case #selector(moveToBeginningOfDocumentAndModifySelection(_:)):
			setSelections(SelectionSet([Selection(anchor: selections.primary.anchor, head: 0)]))
		case #selector(moveToEndOfDocumentAndModifySelection(_:)):
			setSelections(SelectionSet([Selection(anchor: selections.primary.anchor, head: rope.byteCount)]))
		case #selector(pageDown(_:)), #selector(scrollPageDown(_:)): moveVertically(page, extend: false)
		case #selector(pageUp(_:)), #selector(scrollPageUp(_:)): moveVertically(-page, extend: false)
		case #selector(pageDownAndModifySelection(_:)): moveVertically(page, extend: true)
		case #selector(pageUpAndModifySelection(_:)): moveVertically(-page, extend: true)
		default: break
		}
	}

	/// Column counting tabs to the next tab stop.
	func visualColumn(_ offset: Int) -> Int {
		let start = rope.offset(ofLine: rope.line(containing: offset))
		var column = 0
		for scalar in rope.string(in: start..<offset).unicodeScalars {
			column = scalar == "\t" ? (column / format.tabWidth + 1) * format.tabWidth : column + 1
		}
		return column
	}

	/// Removes one indentation level from the start of every line a selection touches.
	private func outdentLines() {
		var lines: [Int] = []
		for s in selections.all {
			let a = rope.line(containing: s.range.lowerBound)
			var b = rope.line(containing: s.range.upperBound)
			// A selection ending at a line start does not include that line.
			if b > a && rope.offset(ofLine: b) == s.range.upperBound { b -= 1 }
			for line in a...b where lines.last.map({ line > $0 }) ?? true { lines.append(line) }
		}
		let edits: [(Range<Int>, String)] = lines.compactMap { line in
			let leading = rope.bytes(in: rope.lineRange(line)).prefix { $0 == 0x20 || $0 == 0x09 }
			guard let first = leading.first else { return nil }
			let count = first == 0x09 ? 1 : min(leading.prefix { $0 == 0x20 }.count, format.indentSize)
			let start = rope.offset(ofLine: line)
			return (start..<(start + count), "")
		}
		guard !edits.isEmpty else { return }
		apply(ChangeSet(edits)) { selections.mapped(through: $0) }
	}

	@objc public func paste(_ sender: Any?) {
		guard let text = NSPasteboard.general.string(forType: .string) else { return }
		// The buffer only holds "\n"; pasted Windows text must not bring "\r" in.
		let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
		replaceSelections { _ in normalized }
	}

	// MARK: NSTextInputClient

	public func insertText(_ string: Any, replacementRange: NSRange) {
		let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
		markedText = ""
		replaceSelections { _ in text }
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
		let r = selections.primary.range
		let start = rope.utf16Offset(ofByte: r.lowerBound)
		return NSRange(location: start, length: rope.utf16Offset(ofByte: r.upperBound) - start)
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
		let rect = NSRect(x: x(of: caret, line: line), y: CGFloat(line) * lineHeight, width: 1, height: lineHeight)
		return window?.convertToScreen(convert(rect, to: nil)) ?? rect
	}

	public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
