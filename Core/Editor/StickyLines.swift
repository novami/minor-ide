import AppKit

extension Notification.Name {
	static let editorStickyLinesDidChange = Notification.Name("MinorIDE.editorStickyLinesDidChange")
}

/// Lines that open the blocks around the top of the view (class, function, if …) stay
/// pinned over the text while scrolling (phase 1f); found by indentation like folding.
extension EditorView {
	/// Pin enclosing lines in every editor (settings.json "sticky_lines").
	public static var showsStickyLines = true {
		didSet { if showsStickyLines != oldValue { NotificationCenter.default.post(name: .editorStickyLinesDidChange, object: nil) } }
	}

	static let maxStickyLines = 3

	/// Lines to pin for the current scroll position, outermost first. A header is pinned only
	/// while its own row is above its slot; the line under the pinned rows decides which.
	func stickyLines() -> [Int] {
		// Simplified mode: lines can be megabytes long, the scan reads whole lines.
		guard Self.showsStickyLines, !document.isSimplified else { return [] }
		let top = visibleRect.minY
		var pinned: [Int] = []
		for _ in 0..<2 {
			let below = line(atY: top + CGFloat(pinned.count) * lineHeight)
			var next: [Int] = []
			for header in rope.scopeHeaders(around: below, tabWidth: format.tabWidth).prefix(Self.maxStickyLines) {
				guard y(ofLine: header) < top + CGFloat(next.count) * lineHeight else { break }
				next.append(header)
			}
			if next == pinned { break }
			pinned = next
		}
		return pinned
	}

	/// Height the pinned rows cover at the top of the view.
	var stickyHeight: CGFloat {
		guard let sticky, !sticky.isHidden else { return 0 }
		return sticky.frame.height
	}

	/// Number of a line for the pinned rows, right aligned at `rightEdge`.
	func drawLineNumber(_ ctx: CGContext, line: Int, rightEdge: CGFloat) {
		drawBatch(ctx, color: NSColor.tertiaryLabelColor.cgColor, lines: [line]) { line in
			let n = numberLayout(line)
			return (n, rightEdge - n.width)
		}
	}
}

/// Pinned rows over the top of the editor's scroll view, gutter included: a sibling of the
/// clip view, so it does not scroll; its text follows the horizontal scroll. A click scrolls
/// to the line and puts the caret there.
@MainActor
public final class StickyLinesView: NSView {
	private weak var editor: EditorView?
	private var observers: [any NSObjectProtocol] = []
	public private(set) var lines: [Int] = []
	public private(set) var drawCount = 0
	private var drawnKey: (lines: [Int], x: CGFloat, lineHeight: CGFloat, gutter: CGFloat)?
	/// Width of the gutter part and x of the editor's origin, in this view.
	private var gutterWidth: CGFloat = 0
	private var textX: CGFloat = 0

	@discardableResult
	public static func install(for editor: EditorView) -> StickyLinesView? {
		guard let scroll = editor.enclosingScrollView else { return nil }
		let view = StickyLinesView(editor: editor)
		scroll.addSubview(view, positioned: .above, relativeTo: scroll.verticalRulerView ?? scroll.contentView)
		editor.sticky = view
		let clip = scroll.contentView
		clip.postsBoundsChangedNotifications = true
		clip.postsFrameChangedNotifications = true
		let center = NotificationCenter.default
		for (name, object) in [(NSView.boundsDidChangeNotification, clip as Any?), (NSView.frameDidChangeNotification, clip),
		                       (.editorStickyLinesDidChange, nil)] {
			view.observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak view] _ in
				MainActor.assumeIsolated { view?.update() }
			})
		}
		view.update()
		return view
	}

	private init(editor: EditorView) {
		self.editor = editor
		super.init(frame: .zero)
		wantsLayer = true
		layerContentsRedrawPolicy = .onSetNeedsDisplay
		clipsToBounds = true
		isHidden = true
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	isolated deinit {
		observers.forEach(NotificationCenter.default.removeObserver)
	}

	public override var isFlipped: Bool { true }
	public override var isOpaque: Bool { true }

	/// Recomputes the pinned lines and the frame; repaints only when what it shows changed.
	func update() {
		guard let editor, let scroll = editor.enclosingScrollView else { return }
		let new = editor.stickyLines()
		isHidden = new.isEmpty
		lines = new
		guard !new.isEmpty else {
			drawnKey = nil // edits while hidden are not tracked
			return
		}
		// The ruler floats over the clip view's left inset.
		let clip = scroll.contentView.frame
		let ruler = scroll.verticalRulerView?.frame
		let left = min(ruler?.minX ?? clip.minX, clip.minX)
		let height = CGFloat(new.count) * editor.lineHeight
		let frame = NSRect(x: left, y: scroll.isFlipped ? clip.minY : clip.maxY - height, width: clip.maxX - left, height: height)
		if frame != self.frame { self.frame = frame }
		gutterWidth = (ruler?.maxX ?? left) - left
		textX = convert(NSPoint.zero, from: editor).x
		let key = (new, textX, editor.lineHeight, gutterWidth)
		if let d = drawnKey, d.lines == key.0, d.x == key.1, d.lineHeight == key.2, d.gutter == key.3 { return }
		drawnKey = key
		needsDisplay = true
	}

	/// After an edit: pinned lines at or below it moved or changed text (an edit in the
	/// other pane of a split does not redraw this editor's visible rows).
	func textChanged(fromLine line: Int) {
		guard let last = lines.last, last >= line else { return }
		drawnKey = nil
		update()
	}

	public override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsDisplay = true
	}

	public override func draw(_ dirtyRect: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext, let editor else { return }
		EditorView.smoothFonts(ctx)
		drawCount += 1
		let gutter = gutterWidth
		let lh = editor.lineHeight
		ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
		ctx.fill(CGRect(x: 0, y: 0, width: gutter, height: bounds.height))
		ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
		ctx.fill(CGRect(x: gutter, y: 0, width: bounds.width - gutter, height: bounds.height))
		for (i, line) in lines.enumerated() {
			let dy = CGFloat(i) * lh - editor.y(ofLine: line)
			ctx.saveGState()
			ctx.translateBy(x: 0, y: dy)
			editor.drawLineNumber(ctx, line: line, rightEdge: gutter - 15)
			ctx.restoreGState()
			ctx.saveGState()
			ctx.clip(to: CGRect(x: gutter, y: CGFloat(i) * lh, width: bounds.width - gutter, height: lh))
			ctx.translateBy(x: textX, y: dy)
			editor.drawText(ctx, rows: [(line, 0)], highlighter: editor.highlighter, textColor: NSColor.textColor.cgColor,
			                xRange: (gutter - textX)...(bounds.width - textX))
			ctx.restoreGState()
		}
		ctx.setFillColor(NSColor.separatorColor.cgColor)
		ctx.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
	}

	/// Scrolls the clicked line to its pinned row and puts the caret at its text.
	public override func mouseDown(with event: NSEvent) {
		guard let editor else { return }
		let row = Int(convert(event.locationInWindow, from: nil).y / editor.lineHeight)
		guard lines.indices.contains(row) else { return }
		let line = lines[row]
		let range = editor.rope.lineRange(line)
		let text = editor.rope.bytes(in: range.lowerBound..<min(range.upperBound, range.lowerBound + 256))
		let indent = text.firstIndex { $0 != 0x20 && $0 != 0x09 } ?? 0
		editor.window?.makeFirstResponder(editor)
		editor.setSelections(SelectionSet(caret: range.lowerBound + indent))
		editor.scroll(NSPoint(x: 0, y: max(0, editor.y(ofLine: line) - CGFloat(row) * editor.lineHeight)))
	}
}
