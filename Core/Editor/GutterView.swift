import AppKit

/// Line numbers in the scroll view's vertical ruler: a view of its own that scrolls with
/// the text vertically and stays put horizontally. Breakpoints and Git marks come later.
@MainActor
public final class GutterView: NSRulerView {
	private weak var editor: EditorView?
	private(set) var drawCount = 0

	/// Installs the gutter as the vertical ruler of the editor's scroll view.
	@discardableResult
	public static func install(for editor: EditorView) -> GutterView? {
		guard let scroll = editor.enclosingScrollView else { return nil }
		let gutter = GutterView(editor: editor, scrollView: scroll)
		scroll.verticalRulerView = gutter
		scroll.hasVerticalRuler = true
		scroll.rulersVisible = true
		return gutter
	}

	private init(editor: EditorView, scrollView: NSScrollView) {
		self.editor = editor
		super.init(scrollView: scrollView, orientation: .verticalRuler)
		clientView = editor
		reservedThicknessForMarkers = 0
		reservedThicknessForAccessoryView = 0
		ruleThickness = editor.gutterWidth
		editor.gutter = self
		// Views do not clip by default since macOS 14: the ruler's layer would grow over the
		// text and its background would cover the editor.
		clipsToBounds = true
	}

	@available(*, unavailable)
	required init(coder: NSCoder) { fatalError("not supported") }

	public override var isFlipped: Bool { true }

	/// Where problem dots are drawn (EditorView.diagnosticDotX).
	static let dotColumn: ClosedRange<CGFloat> = 5...15

	/// The messages of a line's problems as the tooltip of its dot.
	public override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		removeAllToolTips()
		addToolTip(NSRect(x: Self.dotColumn.lowerBound, y: 0, width: Self.dotColumn.upperBound - Self.dotColumn.lowerBound, height: newSize.height),
		           owner: self, userData: nil)
	}

	@objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
		guard let editor else { return "" }
		return editor.diagnosticMessages(line: editor.line(atY: convert(point, to: editor).y)) ?? ""
	}
	public override var isOpaque: Bool { true }

	/// Repaints numbers from an editor y downwards (lines were inserted or removed there).
	func setNeedsDisplay(fromEditorY y: CGFloat) {
		guard let editor else { return }
		let top = max(bounds.minY, convert(NSPoint(x: 0, y: y), from: editor).y)
		setNeedsDisplay(NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.maxY - top)))
	}

	/// A click in the marker column right of the numbers folds or unfolds that line; a click
	/// on a Git change bar at the leading edge shows the change.
	public override func mouseDown(with event: NSEvent) {
		guard let editor else { return }
		let point = convert(event.locationInWindow, from: nil)
		if point.x <= EditorView.gitBarWidth + 4 {
			let y = convert(point, to: editor).y
			if let change = editor.gitChange(atY: y) { return editor.showGitChange(change, from: self, at: point.y) }
		}
		if Self.dotColumn.contains(point.x) {
			let line = editor.line(atY: convert(point, to: editor).y)
			if let d = editor.worstDiagnostics(lines: line...line)[line] { return editor.activate(d) }
		}
		guard point.x >= bounds.width - 14 else { return super.mouseDown(with: event) }
		editor.toggleFold(atLine: editor.line(atY: convert(point, to: editor).y))
	}

	public override func draw(_ dirtyRect: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext, let editor else { return }
		EditorView.smoothFonts(ctx)
		drawCount += 1
		let start = CACurrentMediaTime()
		defer { editor.drawSeconds += CACurrentMediaTime() - start }
		let dirtyRect = dirtyRect.intersection(bounds)
		guard !dirtyRect.isEmpty else { return }
		ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
		ctx.fill(dirtyRect)
		// Line numbers are laid out in editor coordinates and shifted into the gutter.
		let inEditor = convert(dirtyRect, to: editor)
		ctx.saveGState()
		ctx.translateBy(x: 0, y: dirtyRect.minY - inEditor.minY)
		editor.drawLineNumbers(ctx, in: inEditor, rightEdge: bounds.width - 15)
		editor.drawGitChanges(ctx, in: inEditor)
		editor.drawDiagnosticMarks(ctx, in: inEditor)
		ctx.restoreGState()
	}
}
