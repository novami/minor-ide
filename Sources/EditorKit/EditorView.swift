import AVFoundation
import AppKit
import CoreText
import QuartzCore
import Highlight
import MinorCore
import TextEngine

/// Core Text editor view that draws only visible lines from a rope. Multiple selections,
/// basic editing, undo/redo and marked text (dead keys, IME). Styling and the layout
/// cache rework come later in phase 1.
@MainActor
public final class EditorView: NSView, @preconcurrency NSTextInputClient {
	/// Text, undo history and colouring, shared with other editors of the same file.
	public let document: TextDocument
	public var rope: Rope { document.rope }
	/// Byte offsets, always on scalar boundaries.
	public private(set) var selections = SelectionSet()
	/// Head of the primary selection.
	public var caret: Int { selections.primary.head }
	public var history: EditHistory { document.history }
	/// Positions that follow edits, undo and redo included.
	public var anchors: AnchorSet {
		get { document.anchors }
		set { document.anchors = newValue }
	}
	/// Indentation and tab display of the document.
	public var format: FormatSettings {
		get { document.format }
		set { document.format = newValue }
	}

	func tabWidthDidChange() {
		layoutCache.removeAll()
		needsDisplay = true
	}

	public let font: NSFont
	let ctFont: CTFont
	public let lineHeight: CGFloat
	let ascent: CGFloat
	let gutterWidth: CGFloat
	let textInset: CGFloat = 8
	private let newlineWidth: CGFloat
	private var markedText = ""
	/// Text removed by ⌃K, inserted back by ⌃Y.
	private var killBuffer = ""

	enum DragUnit { case character, word, line }
	/// Mouse selection in progress: the unit and range of the first click, the selections kept
	/// beside it (Shift, Option) and the start of an Option+drag column.
	private struct Drag {
		var unit: DragUnit
		var origin: Range<Int>
		var others: [Selection]
		var column: (x: CGFloat, line: Int)?
	}
	private var drag: Drag?
	/// Goal x of each selection for up/down moves, in selection order.
	private var goalXs: [CGFloat]?

	private var layoutCache = LayoutCache()
	private var numberCache = LayoutCache()
	private let ascii: AsciiGlyphs
	private var batchGlyphs: [CGGlyph] = []
	private var batchPositions: [CGPoint] = []
	let textAttributes: [NSAttributedString.Key: Any]

	/// Number of draw passes, drawn lines and time spent in draw(_:), for benchmarks.
	public internal(set) var drawCount = 0
	public internal(set) var drawnLines = 0
	public internal(set) var drawSeconds = 0.0

	/// Carets live in their own layer, so blinking and caret moves do not redraw text.
	let caretLayer = CAShapeLayer()
	var caretsDirty = true
	/// Lines whose carets are in `caretLayer`; a scroll past them rebuilds the path.
	var caretLines = 0..<0
	/// Set once an assistive app (VoiceOver) asked for text; changes are posted only then.
	var accessibilityClientSeen = false
	/// Measures key-to-frame latency when set (benchmark, MINORIDE_LATENCY=1).
	public var latencyMonitor: LatencyMonitor?
	/// Folded regions as byte ranges (`Rope.foldRange`), sorted by start; nested folds allowed.
	public internal(set) var folds: [Range<Int>] = []
	/// Rows on screen after folding.
	public internal(set) var display = DisplayMap()
	/// Header lines of folds, drawn with a placeholder after the text.
	var foldedHeaders: Set<Int> = []

	/// Language of the document: colouring, comments, brackets; nil for plain text.
	public var language: SyntaxLanguage? {
		get { document.language }
		set { document.language = newValue }
	}
	/// Syntax colouring; nil for plain text.
	public var highlighter: SyntaxHighlighter? {
		get { document.highlighter }
		set { document.highlighter = newValue }
	}
	private var clipObserver: (any NSObjectProtocol)?
	/// Builds the right-click menu (localized by the app).
	public var contextMenuProvider: ((EditorView) -> NSMenu)?
	let speech = AVSpeechSynthesizer()
	/// The caret move in progress, for the VoiceOver notification.
	var accessibilityMove: AccessibilityMove?
	var tokenColors: [NSColor?] = []
	var colorGlyphs: [[CGGlyph]] = []
	var colorPositions: [[CGPoint]] = []

	/// Find results, sorted; highlighted under the text. They follow edits until the next search.
	public private(set) var findMatches: [Range<Int>] = []

	public func setFindMatches(_ matches: [Range<Int>]) {
		guard matches != findMatches else { return }
		findMatches = matches
		needsDisplay = true
	}

	/// Line numbers, drawn in the scroll view's vertical ruler.
	public internal(set) weak var gutter: GutterView?

	public convenience init(text: String, font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
		self.init(document: TextDocument(text: text), font: font)
	}

	/// An editor of `document`; several editors of one document make a split view.
	public init(document: TextDocument, font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
		self.document = document
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
		clipsToBounds = true // drawing stays inside the view (default is false since macOS 14)
		setUpCaretLayer()
		updateTokenColors()
		document.attach(self)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	public override var isFlipped: Bool { true }
	public override var acceptsFirstResponder: Bool { true }
	public override var isOpaque: Bool { true }

	public override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		layoutCache.removeAll() // fallback CTLines carry their colour
		updateTokenColors()
		needsDisplay = true
		gutter?.needsDisplay = true
		setNeedsCaretUpdate()
	}

	/// Height follows the line count; width follows the scroll view (no horizontal scroll yet).
	public func updateSize() {
		// The gutter (vertical ruler) floats over the clip view and insets it.
		let width = enclosingScrollView.map { $0.contentSize.width - $0.contentView.contentInsets.left - $0.contentView.contentInsets.right } ?? frame.width
		let size = NSSize(width: max(0, width), height: CGFloat(rowCount) * lineHeight + lineHeight)
		guard size != frame.size else { return }
		let widthChanged = size.width != frame.width
		setFrameSize(size)
		// Layer contents are redrawn only on request (.onSetNeedsDisplay), not on resize.
		if widthChanged { needsDisplay = true }
	}

	/// The clip view does not resize its document view, so the width follows its frame here
	/// (window resize, sidebar, layout of a window built before it had a size).
	public override func viewDidMoveToSuperview() {
		super.viewDidMoveToSuperview()
		if let token = clipObserver { NotificationCenter.default.removeObserver(token) }
		clipObserver = nil
		guard let clip = superview as? NSClipView else { return }
		clip.postsFrameChangedNotifications = true
		clipObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.updateSize() }
		}
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

		let shown = lines(inY: dirtyRect.minY, dirtyRect.maxY)
		let first = shown.first ?? 0, last = shown.last ?? -1
		let textColor = NSColor.textColor.cgColor
		let visible = selections.all.filter {
			rope.line(containing: $0.range.upperBound) >= first && rope.line(containing: $0.range.lowerBound) <= last
		}

		if first <= last {
			drawnLines += shown.count
			drawFindMatches(ctx, lines: first...last)
			drawSelectionBackground(ctx, visible, lines: first...last)
			if let highlighter {
				highlighter.prepare(upTo: last, in: rope)
				drawHighlighted(ctx, lines: shown, highlighter: highlighter, textColor: textColor)
			} else {
				drawBatch(ctx, color: textColor, lines: shown) { line in (layout(line), textInset) }
			}
			if !foldedHeaders.isEmpty { drawFoldPlaceholders(ctx, lines: shown) }
		}
		if !markedText.isEmpty, visible.contains(selections.primary) { drawMarkedText(ctx, at: caret) }
		let keep = (first - 300)...(max(first, last) + 300)
		layoutCache.trim(keep: keep, limit: 1500) // bounds memory when scrolling through large files
	}

	public override func viewWillDraw() {
		super.viewWillDraw()
		updateCaretsIfNeeded() // scrolling exposes lines whose carets are not in the path yet
	}

	public override func layout() {
		super.layout()
		updateCaretsIfNeeded()
	}

	/// Line numbers for the gutter; `rect` is in editor coordinates.
	func drawLineNumbers(_ ctx: CGContext, in rect: NSRect, rightEdge: CGFloat) {
		let shown = lines(inY: rect.minY, rect.maxY)
		guard let first = shown.first, let last = shown.last else { return }
		drawnLines += shown.count
		drawBatch(ctx, color: NSColor.tertiaryLabelColor.cgColor, lines: shown) { line in
			let n = numberLayout(line)
			return (n, rightEdge - n.width)
		}
		drawFoldMarkers(ctx, lines: shown, centerX: rightEdge + 8)
		numberCache.trim(keep: (first - 300)...(last + 300), limit: 1500)
	}

	private func drawFindMatches(_ ctx: CGContext, lines: ClosedRange<Int>) {
		guard !findMatches.isEmpty else { return }
		let start = rope.offset(ofLine: lines.lowerBound), end = rope.lineRange(lines.upperBound).upperBound
		// First match ending in the drawn lines.
		var lo = 0, hi = findMatches.count
		while lo < hi {
			let mid = (lo + hi) / 2
			if findMatches[mid].upperBound < start { lo = mid + 1 } else { hi = mid }
		}
		ctx.setFillColor(NSColor.findHighlightColor.withAlphaComponent(0.45).cgColor)
		for m in findMatches[lo...] {
			guard m.lowerBound <= end else { break }
			let lowerLine = rope.line(containing: m.lowerBound), upperLine = rope.line(containing: m.upperBound)
			for line in max(lowerLine, lines.lowerBound)...min(upperLine, lines.upperBound) where !display.isHidden(line) {
				let x0 = line == lowerLine ? x(of: m.lowerBound, line: line) : textInset
				let x1 = line == upperLine ? x(of: m.upperBound, line: line) : textInset + layout(line).width + newlineWidth
				ctx.fill(CGRect(x: x0, y: y(ofLine: line), width: max(0, x1 - x0), height: lineHeight))
			}
		}
	}

	/// Current-line highlight under carets, then selected ranges.
	private func drawSelectionBackground(_ ctx: CGContext, _ visible: [Selection], lines: ClosedRange<Int>) {
		ctx.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.15).cgColor)
		var lastHighlighted = -1
		for s in visible where s.isEmpty {
			let line = rope.line(containing: s.head)
			guard line != lastHighlighted, lines.contains(line) else { continue }
			lastHighlighted = line
			ctx.fill(CGRect(x: 0, y: y(ofLine: line), width: bounds.width, height: lineHeight))
		}
		let color = window?.firstResponder === self ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
		ctx.setFillColor(color.cgColor)
		let textStart = textInset
		for s in visible where !s.isEmpty {
			let lowerLine = rope.line(containing: s.range.lowerBound)
			let upperLine = rope.line(containing: s.range.upperBound)
			for line in max(lowerLine, lines.lowerBound)...min(upperLine, lines.upperBound) where !display.isHidden(line) {
				let x0 = line == lowerLine ? x(of: s.range.lowerBound, line: line) : textStart
				// A selected line break shows as a short block past the line end.
				let x1 = line == upperLine ? x(of: s.range.upperBound, line: line) : textStart + layout(line).width + newlineWidth
				ctx.fill(CGRect(x: x0, y: y(ofLine: line), width: max(0, x1 - x0), height: lineHeight))
			}
		}
	}

	/// Fast-path lines are batched into one glyph draw per colour; CTLine fallbacks draw alone.
	private func drawBatch(_ ctx: CGContext, color: CGColor, lines: [Int], _ layoutAt: (Int) -> (LineLayout, CGFloat)) {
		ctx.setFillColor(color)
		batchGlyphs.removeAll(keepingCapacity: true)
		batchPositions.removeAll(keepingCapacity: true)
		for line in lines {
			let (l, x) = layoutAt(line)
			let baseline = y(ofLine: line) + ascent + 1
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

	/// Pending dead key or composition, drawn over the text at the caret.
	private func drawMarkedText(_ ctx: CGContext, at offset: Int) {
		let line = rope.line(containing: offset)
		let cx = x(of: offset, line: line)
		let y = y(ofLine: line)
		let marked = CTLineCreateWithAttributedString(NSAttributedString(string: markedText, attributes:
			textAttributes.merging([.underlineStyle: NSUnderlineStyle.single.rawValue]) { $1 }))
		ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
		ctx.fill(CGRect(x: cx, y: y, width: CTLineGetTypographicBounds(marked, nil, nil, nil), height: lineHeight))
		ctx.setFillColor(NSColor.textColor.cgColor)
		LineLayout.withBaseline(ctx, CGPoint(x: cx, y: y + ascent + 1)) { CTLineDraw(marked, ctx) }
	}

	func layout(_ line: Int) -> LineLayout {
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
	func x(of offset: Int, line: Int) -> CGFloat {
		let column = rope.utf16Offset(ofByte: offset) - rope.utf16Offset(ofByte: rope.offset(ofLine: line))
		return textInset + layout(line).x(atUnit: column)
	}

	private func x(of offset: Int) -> CGFloat { x(of: offset, line: rope.line(containing: offset)) }

	private func lineRect(_ line: Int) -> NSRect {
		NSRect(x: 0, y: y(ofLine: line), width: bounds.width, height: lineHeight)
	}

	func invalidate(_ set: SelectionSet) {
		for s in set.all {
			let a = rope.line(containing: s.range.lowerBound)
			let b = s.isEmpty ? a : rope.line(containing: s.range.upperBound)
			let top = y(ofLine: a)
			setNeedsDisplay(NSRect(x: 0, y: top, width: bounds.width, height: y(ofLine: b) - top + lineHeight))
		}
	}

	// MARK: Selections

	public func setSelections(_ new: SelectionSet) { setSelections(new, keepGoal: false) }

	private func setSelections(_ new: SelectionSet, keepGoal: Bool) {
		if !keepGoal { goalXs = nil }
		guard new != selections else { return }
		invalidate(selections)
		selections = new
		revealSelections()
		setNeedsCaretUpdate()
		postAccessibilityChange(edited: false)
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
			let target = display.line(atRow: min(max(0, display.row(of: rope.line(containing: from)) + delta), rowCount - 1))
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
		let target = layout(line).unitIndex(atX: x - textInset)
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

	private func line(at point: NSPoint) -> Int { line(atY: point.y) }

	private func offset(at point: NSPoint) -> Int { offset(atX: point.x, line: line(at: point)) }

	// MARK: Editing

	/// Replaces a byte range, leaving a single caret after the new text.
	public func replace(_ range: Range<Int>, with text: String) {
		apply(ChangeSet([(range, text)]), kind: .other) { cs in SelectionSet(caret: cs.map(range.upperBound, bias: .after)) }
	}

	/// Applies several replacements as one undo step; selections follow the edit.
	public func replace(_ edits: [(Range<Int>, String)]) {
		apply(ChangeSet(edits), kind: .other) { selections.mapped(through: $0) }
	}

	/// Replaces every selection with its own text; carets end after the new text.
	private func replaceSelections(_ kind: EditKind = .other, _ text: (Selection) -> String) {
		replaceSelections(kind) { s in (s.range, text(s)) }
	}

	private func replaceSelections(_ kind: EditKind = .other, _ edit: (Selection) -> (Range<Int>, String)) {
		let edits = selections.all.map(edit)
		apply(ChangeSet(edits), kind: kind) { cs in
			SelectionSet(edits.map { Selection(caret: cs.map($0.0.upperBound, bias: .after)) }, primary: selections.primaryIndex)
		}
	}

	/// Applies and records the edit as one transaction.
	func apply(_ changes: ChangeSet, kind: EditKind, selectionsAfter: (ChangeSet) -> SelectionSet) {
		guard !changes.isEmpty else { return }
		let before = rope, selectionsBefore = selections
		apply(changes) { selectionsAfter($0) }
		document.history.record(Transaction(changes, on: before, before: selectionsBefore, after: selections,
		                           kind: kind, time: ProcessInfo.processInfo.systemUptime))
	}

	/// Applies the edit through the document; every editor of it follows.
	private func apply(_ changes: ChangeSet, selectionsAfter: (ChangeSet) -> SelectionSet) {
		guard !changes.isEmpty else { return }
		document.apply(changes, from: self, selectionsAfter: selectionsAfter)
	}

	/// Before the document changes: old selections are repainted away.
	func willEdit() {
		invalidate(selections)
	}

	/// After the document changed: sets the selections and repaints as little as possible.
	/// Only the editor that made the edit unfolds around and scrolls to its carets.
	func didEdit(_ changes: ChangeSet, _ edit: TextDocument.Edit, selections newSelections: SelectionSet, isSource: Bool) {
		let firstLine = edit.firstLine, lastLine = edit.lastLine, oldLines = edit.oldLines, sameLines = edit.sameLines
		if !findMatches.isEmpty { findMatches = changes.mapUntouched(findMatches) }
		var foldsChanged = false
		if !folds.isEmpty {
			let mapped = changes.mapUntouched(folds, closedEnd: true)
			foldsChanged = mapped.count != folds.count
			folds = mapped
			if foldsChanged || !sameLines { rebuildDisplay() }
		}
		selections = newSelections
		if isSource, revealSelections() { foldsChanged = true }
		goalXs = nil
		setNeedsCaretUpdate()
		postAccessibilityChange(edited: true)

		if foldsChanged {
			if sameLines {
				for line in edit.editedLines { layoutCache[line] = nil }
			} else {
				layoutCache.shift(from: firstLine, removed: lastLine - firstLine, delta: rope.lineCount - oldLines)
			}
			updateSize()
			needsDisplay = true
			gutter?.needsDisplay = true
		} else if sameLines {
			for line in edit.editedLines {
				layoutCache[line] = nil
				setNeedsDisplay(lineRect(line))
			}
		} else {
			layoutCache.shift(from: firstLine, removed: lastLine - firstLine, delta: rope.lineCount - oldLines)
			if rope.lineCount != oldLines || !folds.isEmpty { updateSize() }
			let visible = visibleRect
			let top = y(ofLine: firstLine)
			let below = NSRect(x: 0, y: top, width: bounds.width, height: max(0, visible.maxY - top))
			setNeedsDisplay(below)
			if rope.lineCount != oldLines { gutter?.setNeedsDisplay(fromEditorY: below.minY) }
		}
		// A change of state (an opened comment or string) recolours lines below the edit.
		if let syntaxDirty = edit.syntaxDirty, syntaxDirty.upperBound > edit.newLastLine, !foldsChanged {
			let top = y(ofLine: edit.newLastLine + 1)
			let bottom = min(visibleRect.maxY, y(ofLine: min(syntaxDirty.upperBound, rope.lineCount - 1)) + lineHeight)
			if bottom > top { setNeedsDisplay(NSRect(x: 0, y: top, width: bounds.width, height: bottom - top)) }
		}
		invalidate(selections)
		if isSource { scrollCaretVisible() }
	}

	// MARK: Input

	public override func keyDown(with event: NSEvent) {
		latencyMonitor?.keyDown(at: event.timestamp)
		if !(inputContext?.handleEvent(event) ?? false) {
			interpretKeyEvents([event])
		}
	}

	public override func mouseDown(with event: NSEvent) {
		if hasMarkedText() { // a click drops a pending dead key or composition
			inputContext?.discardMarkedText()
			discardMarkedText()
		}
		mouseDown(at: convert(event.locationInWindow, from: nil), clicks: event.clickCount, modifiers: event.modifierFlags)
	}

	public override func mouseDragged(with event: NSEvent) {
		autoscroll(with: event)
		mouseDragged(to: convert(event.locationInWindow, from: nil))
	}

	public override func mouseUp(with event: NSEvent) { drag = nil }

	/// Text cursor (I-beam) over the text, as in every macOS text view.
	public override func resetCursorRects() {
		addCursorRect(bounds, cursor: .iBeam) // AppKit clips it to the visible part
	}

	/// Click: caret; double: word; triple: line. Shift extends the primary selection,
	/// Option adds a selection (Option+drag selects a column).
	func mouseDown(at point: NSPoint, clicks: Int, modifiers: NSEvent.ModifierFlags) {
		if !foldedHeaders.isEmpty, case let l = line(at: point), foldedHeaders.contains(l), placeholderRect(l).contains(point) {
			toggleFold(atLine: l)
			return
		}
		let offset = offset(at: point)
		let unit: DragUnit = clicks >= 3 ? .line : clicks == 2 ? .word : .character
		var others: [Selection] = []
		var origin = range(of: unit, at: offset)
		if modifiers.contains(.shift) {
			others = selections.all.enumerated().filter { $0.offset != selections.primaryIndex }.map(\.element)
			let anchor = selections.primary.anchor
			origin = anchor..<anchor
		} else if modifiers.contains(.option) {
			others = selections.all
		}
		let column = modifiers.contains(.option) && !modifiers.contains(.shift) && clicks == 1
		drag = Drag(unit: unit, origin: origin, others: others,
		            column: column ? (x: point.x, line: line(at: point)) : nil)
		mouseDragged(to: point)
	}

	func mouseDragged(to point: NSPoint) {
		guard let drag else { return }
		if let start = drag.column {
			let current = line(at: point)
			let lines = stride(from: start.line, through: current, by: current >= start.line ? 1 : -1).filter { !display.isHidden($0) }
			let block = lines.map { Selection(anchor: offset(atX: start.x, line: $0), head: offset(atX: point.x, line: $0)) }
			setSelections(SelectionSet(drag.others + block, primary: drag.others.count + block.count - 1))
			return
		}
		let r = range(of: drag.unit, at: offset(at: point)), o = drag.origin
		let s = r.lowerBound < o.lowerBound ? Selection(anchor: o.upperBound, head: r.lowerBound)
			: Selection(anchor: o.lowerBound, head: max(r.upperBound, o.upperBound))
		setSelections(SelectionSet(drag.others + [s], primary: drag.others.count))
	}

	private func range(of unit: DragUnit, at offset: Int) -> Range<Int> {
		switch unit {
		case .character: return offset..<offset
		case .word: return rope.wordRange(at: offset)
		case .line:
			let line = rope.line(containing: offset)
			return rope.offset(ofLine: line)..<(line + 1 < rope.lineCount ? rope.offset(ofLine: line + 1) : rope.byteCount)
		}
	}

	/// Called when the editor gets keyboard focus (the active pane of a split).
	public var onFocus: ((EditorView) -> Void)?

	public override func becomeFirstResponder() -> Bool {
		invalidate(selections) // selection colour follows focus
		setNeedsCaretUpdate()
		guard super.becomeFirstResponder() else { return false }
		onFocus?(self)
		return true
	}

	/// Takes selections, folds and scroll position from another editor of the same document
	/// (a new split pane, or the pane that stays when the other one closes).
	public func adoptViewState(of other: EditorView) {
		setFolds(other.folds)
		setSelections(other.selections)
		updateSize()
		scroll(other.visibleRect.origin)
	}

	public override func resignFirstResponder() -> Bool {
		invalidate(selections)
		setNeedsCaretUpdate()
		return super.resignFirstResponder()
	}

	public override func doCommand(by selector: Selector) {
		accessibilityMove = EditorView.accessibilityMove(for: selector)
		defer { accessibilityMove = nil }
		var page: Int { max(1, Int(min(visibleRect.height, 1e6) / lineHeight) - 1) }
		let lineStart = { (o: Int) in self.rope.offset(ofLine: self.rope.line(containing: o)) }
		let lineEnd = { (o: Int) in self.rope.lineRange(self.rope.line(containing: o)).upperBound }
		switch selector {
		case #selector(deleteBackward(_:)):
			replaceSelections(.deleting) { s in (s.isEmpty ? emptyPair(around: s.head) ?? previous(s.head)..<s.head : s.range, "") }
		case #selector(deleteForward(_:)):
			replaceSelections(.deleting) { s in (s.isEmpty ? s.head..<next(s.head) : s.range, "") }
		case #selector(insertNewline(_:)) where language != nil: insertNewlineSmart()
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

		// System bindings (emacs-style keys, ⌥ and ⌘ variants, DefaultKeyBinding.dict).
		case #selector(moveWordLeft(_:)), #selector(moveWordBackward(_:)):
			move(extend: false) { rope.wordStart(before: $0.range.lowerBound) }
		case #selector(moveWordRight(_:)), #selector(moveWordForward(_:)):
			move(extend: false) { rope.wordEnd(after: $0.range.upperBound) }
		case #selector(moveWordLeftAndModifySelection(_:)), #selector(moveWordBackwardAndModifySelection(_:)):
			move(extend: true) { rope.wordStart(before: $0.head) }
		case #selector(moveWordRightAndModifySelection(_:)), #selector(moveWordForwardAndModifySelection(_:)):
			move(extend: true) { rope.wordEnd(after: $0.head) }
		case #selector(moveBackward(_:)): doCommand(by: #selector(moveLeft(_:)))
		case #selector(moveForward(_:)): doCommand(by: #selector(moveRight(_:)))
		case #selector(moveBackwardAndModifySelection(_:)): doCommand(by: #selector(moveLeftAndModifySelection(_:)))
		case #selector(moveForwardAndModifySelection(_:)): doCommand(by: #selector(moveRightAndModifySelection(_:)))
		case #selector(moveToBeginningOfParagraph(_:)): move(extend: false) { lineStart($0.head) }
		case #selector(moveToEndOfParagraph(_:)): move(extend: false) { lineEnd($0.head) }
		case #selector(moveToBeginningOfParagraphAndModifySelection(_:)): move(extend: true) { lineStart($0.head) }
		case #selector(moveToEndOfParagraphAndModifySelection(_:)): move(extend: true) { lineEnd($0.head) }
		case #selector(deleteWordBackward(_:)):
			replaceSelections(.other) { s in (s.isEmpty ? rope.wordStart(before: s.head)..<s.head : s.range, "") }
		case #selector(deleteWordForward(_:)):
			replaceSelections(.other) { s in (s.isEmpty ? s.head..<rope.wordEnd(after: s.head) : s.range, "") }
		case #selector(deleteBackwardByDecomposingPreviousCharacter(_:)): doCommand(by: #selector(deleteBackward(_:)))
		case #selector(deleteToBeginningOfLine(_:)), #selector(deleteToBeginningOfParagraph(_:)):
			replaceSelections(.other) { s in
				guard s.isEmpty else { return (s.range, "") }
				let start = lineStart(s.head)
				return ((start == s.head ? previous(s.head) : start)..<s.head, "")
			}
		case #selector(deleteToEndOfLine(_:)), #selector(deleteToEndOfParagraph(_:)):
			// ⌃K: kill to the end of the line, or the newline itself at the end.
			var killed: [String] = []
			replaceSelections(.other) { s in
				let end = lineEnd(s.head)
				let range = s.isEmpty ? s.head..<(end == s.head ? next(s.head) : end) : s.range
				killed.append(rope.string(in: range))
				return (range, "")
			}
			killBuffer = killed.joined(separator: "\n")
		case #selector(yank(_:)): if !killBuffer.isEmpty { replaceSelections { _ in killBuffer } }
		case #selector(transpose(_:)): transposeCharacters()
		case #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
			doCommand(by: #selector(insertNewline(_:)))
		case #selector(insertTabIgnoringFieldEditor(_:)): doCommand(by: #selector(insertTab(_:)))
		case #selector(scrollToBeginningOfDocument(_:)): scroll(NSPoint(x: visibleRect.minX, y: 0))
		case #selector(scrollToEndOfDocument(_:)): scroll(NSPoint(x: visibleRect.minX, y: bounds.height - visibleRect.height))
		case #selector(scrollLineUp(_:)): scroll(NSPoint(x: visibleRect.minX, y: visibleRect.minY - lineHeight))
		case #selector(scrollLineDown(_:)): scroll(NSPoint(x: visibleRect.minX, y: visibleRect.minY + lineHeight))
		case #selector(centerSelectionInVisibleArea(_:)):
			let y = y(ofLine: rope.line(containing: caret))
			scroll(NSPoint(x: visibleRect.minX, y: y - (visibleRect.height - lineHeight) / 2))
		default: break
		}
	}

	/// ⌃T: swaps the characters around each caret; at the end of a line the two before it.
	private func transposeCharacters() {
		guard selections.all.allSatisfy(\.isEmpty) else { return }
		replaceSelections(.other) { s in
			var mid = s.head
			if mid == rope.lineRange(rope.line(containing: mid)).upperBound { mid = previous(mid) }
			let start = previous(mid), end = next(mid)
			guard start < mid, mid < end else { return (s.range, "") }
			let before = rope.string(in: start..<mid), after = rope.string(in: mid..<end)
			guard before != "\n", after != "\n" else { return (s.range, "") }
			return (start..<end, after + before)
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
		apply(ChangeSet(edits), kind: .other) { selections.mapped(through: $0) }
	}

	// MARK: Undo, clipboard

	@objc public func undo(_ sender: Any?) {
		discardMarkedText()
		guard let step = document.history.undo() else { return }
		for t in step.transactions.reversed() { apply(t.inverse) { _ in t.selectionsBefore } }
	}

	@objc public func redo(_ sender: Any?) {
		discardMarkedText()
		guard let step = document.history.redo() else { return }
		for t in step.transactions { apply(t.changes) { _ in t.selectionsAfter } }
	}

	/// The next edit starts a new undo step.
	public func sealUndo() { document.history.seal() }

	private var selectedText: String {
		selections.all.filter { !$0.isEmpty }.map { rope.string(in: $0.range) }.joined(separator: "\n")
	}

	@objc public func copy(_ sender: Any?) {
		guard selections.all.contains(where: { !$0.isEmpty }) else { return }
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(selectedText, forType: .string)
	}

	@objc public func cut(_ sender: Any?) {
		guard selections.all.contains(where: { !$0.isEmpty }) else { return }
		copy(sender)
		replaceSelections { _ in "" }
	}

	@objc public override func selectAll(_ sender: Any?) {
		setSelections(SelectionSet([Selection(anchor: 0, head: rope.byteCount)]))
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
		// Marked text is drawn over the document, not stored in it: replacing "its" range
		// means inserting at the caret, not overwriting the text after it.
		let replacesMarked = hasMarkedText() && replacementRange == markedRange()
		discardMarkedText()
		if !replacesMarked, let range = byteRange(replacementRange) {
			// Press-and-hold accents and some input methods replace text already in the document.
			apply(ChangeSet([(range, text)]), kind: .other) { cs in SelectionSet(caret: cs.map(range.upperBound, bias: .after)) }
			return
		}
		if text.utf8.count == 1, language != nil, typePairCharacter(text.utf8.first!) { return }
		replaceSelections(text.contains("\n") ? .other : .typing) { _ in text }
	}

	public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
		if !(hasMarkedText() && replacementRange == markedRange()), let range = byteRange(replacementRange) {
			setSelections(SelectionSet([Selection(anchor: range.lowerBound, head: range.upperBound)]))
		}
		markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
		setNeedsDisplay(lineRect(rope.line(containing: caret)))
	}

	/// The input method accepts the marked text as typed (dictation commits this way).
	public func unmarkText() {
		guard hasMarkedText() else { return }
		let text = markedText
		discardMarkedText()
		replaceSelections(.typing) { _ in text }
	}

	/// Drops a pending dead key or composition (click, undo).
	func discardMarkedText() {
		guard hasMarkedText() else { return }
		markedText = ""
		setNeedsDisplay(lineRect(rope.line(containing: caret)))
	}

	public func selectedRange() -> NSRange { utf16Range(selections.primary.range) }

	public func markedRange() -> NSRange {
		markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
			: NSRange(location: rope.utf16Offset(ofByte: caret), length: markedText.utf16.count)
	}

	public func hasMarkedText() -> Bool { !markedText.isEmpty }

	public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
		guard let bytes = byteRange(range) else { return nil }
		actualRange?.pointee = utf16Range(bytes)
		return NSAttributedString(string: rope.string(in: bytes), attributes: textAttributes)
	}

	public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

	/// Screen rect of the range's first line; input methods place their windows below it.
	public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
		let bytes = byteRange(range) ?? caret..<caret
		let line = rope.line(containing: bytes.lowerBound)
		let end = min(bytes.upperBound, rope.lineRange(line).upperBound)
		actualRange?.pointee = utf16Range(bytes.lowerBound..<end)
		let minX = x(of: bytes.lowerBound, line: line)
		let rect = NSRect(x: minX, y: y(ofLine: line), width: max(1, x(of: end, line: line) - minX), height: lineHeight)
		return window?.convertToScreen(convert(rect, to: nil)) ?? rect
	}

	public func characterIndex(for point: NSPoint) -> Int {
		guard let window else { return NSNotFound }
		let local = convert(window.convertPoint(fromScreen: point), from: nil)
		return rope.utf16Offset(ofByte: offset(at: local))
	}

	/// Byte range of a UTF-16 range clamped to the document; nil for NSNotFound.
	func byteRange(_ range: NSRange) -> Range<Int>? {
		guard range.location != NSNotFound else { return nil }
		let start = min(range.location, rope.utf16Count)
		let end = min(start + range.length, rope.utf16Count)
		return rope.byteOffset(ofUTF16: start)..<rope.byteOffset(ofUTF16: end)
	}

	func utf16Range(_ range: Range<Int>) -> NSRange {
		let start = rope.utf16Offset(ofByte: range.lowerBound)
		return NSRange(location: start, length: rope.utf16Offset(ofByte: range.upperBound) - start)
	}
}

extension EditorView: NSMenuItemValidation {
	public func validateMenuItem(_ item: NSMenuItem) -> Bool {
		switch item.action {
		case #selector(undo(_:)): history.canUndo
		case #selector(redo(_:)): history.canRedo
		case #selector(copy(_:)), #selector(cut(_:)): selections.all.contains { !$0.isEmpty }
		case #selector(paste(_:)): NSPasteboard.general.string(forType: .string) != nil
		case #selector(unfold(_:)), #selector(unfoldAll(_:)): !folds.isEmpty
		case #selector(toggleComment(_:)): language != nil
		case #selector(stopSpeaking(_:)): speech.isSpeaking
		case #selector(moveLinesUp(_:)): selectedLineBlocks().first.map { $0.lowerBound > 0 } ?? false
		case #selector(moveLinesDown(_:)): selectedLineBlocks().last.map { $0.upperBound < rope.lineCount - 1 } ?? false
		default: true
		}
	}
}
