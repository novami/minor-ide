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
	}

	@available(*, unavailable)
	required init(coder: NSCoder) { fatalError("not supported") }

	public override var isFlipped: Bool { true }
	public override var isOpaque: Bool { true }

	/// Repaints numbers from an editor y downwards (lines were inserted or removed there).
	func setNeedsDisplay(fromEditorY y: CGFloat) {
		guard let editor else { return }
		let top = max(bounds.minY, convert(NSPoint(x: 0, y: y), from: editor).y)
		setNeedsDisplay(NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.maxY - top)))
	}

	/// A click in the marker column right of the numbers folds or unfolds that line.
	public override func mouseDown(with event: NSEvent) {
		guard let editor else { return }
		let point = convert(event.locationInWindow, from: nil)
		guard point.x >= bounds.width - 14 else { return super.mouseDown(with: event) }
		editor.toggleFold(atLine: editor.line(atY: convert(point, to: editor).y))
	}

	public override func draw(_ dirtyRect: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext, let editor else { return }
		drawCount += 1
		let start = CACurrentMediaTime()
		defer { editor.drawSeconds += CACurrentMediaTime() - start }
		ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
		ctx.fill(dirtyRect)
		// Line numbers are laid out in editor coordinates and shifted into the gutter.
		let inEditor = convert(dirtyRect, to: editor)
		ctx.saveGState()
		ctx.translateBy(x: 0, y: dirtyRect.minY - inEditor.minY)
		editor.drawLineNumbers(ctx, in: inEditor, rightEdge: bounds.width - 15)
		ctx.restoreGState()
	}
}
