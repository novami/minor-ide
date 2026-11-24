import AppKit

/// A problem in the text (a language server's diagnostic): a wavy underline, a dot in the
/// gutter and a mark along the right edge.
public struct EditorDiagnostic: Sendable, Equatable {
	/// Another place that explains the problem; line and character as the server counts them.
	public struct Related: Sendable, Equatable {
		public var url: URL
		public var line: Int
		public var character: Int
		public var message: String

		public init(url: URL, line: Int, character: Int, message: String) {
			self.url = url
			self.line = line
			self.character = character
			self.message = message
		}
	}

	public enum Severity: Int, Sendable, Comparable {
		case error = 1, warning, information, hint
		public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
	}

	public var range: Range<Int>
	public var severity: Severity
	public var message: String
	/// Who reported it ("compiler", "staticcheck"…).
	public var source: String?
	public var code: String?
	/// Where the code is explained.
	public var link: URL?
	public var related: [Related]
	/// Unused code: the text is drawn faded.
	public var unnecessary: Bool
	/// What the reporter needs back (the language server's diagnostic for quick fixes).
	public var data: JSONValue

	public init(range: Range<Int>, severity: Severity, message: String, source: String? = nil, code: String? = nil,
	            link: URL? = nil, related: [Related] = [], unnecessary: Bool = false, data: JSONValue = .null) {
		self.range = range
		self.severity = severity
		self.message = message
		self.source = source
		self.code = code
		self.link = link
		self.related = related
		self.unnecessary = unnecessary
		self.data = data
	}

	public var color: NSColor {
		switch severity {
		case .error: .systemRed
		case .warning: .systemOrange
		case .information: .systemBlue
		case .hint: .secondaryLabelColor
		}
	}
}

struct DiagnosticMark {
	var diagnostic: EditorDiagnostic
	var start: AnchorID
	var end: AnchorID
}

extension TextDocument {
	/// Replaces the problems; ranges are byte offsets in the current text. They follow edits
	/// until the next call.
	public func setDiagnostics(_ items: [EditorDiagnostic]) {
		if items.isEmpty && diagnosticMarks.isEmpty { return }
		for m in diagnosticMarks {
			anchors.remove(m.start)
			anchors.remove(m.end)
		}
		let n = rope.byteCount
		diagnosticMarks = items.map { d in
			let lo = min(d.range.lowerBound, n), hi = min(max(d.range.upperBound, lo), n)
			return DiagnosticMark(diagnostic: d, start: anchors.add(at: lo, bias: .after), end: anchors.add(at: hi, bias: .before))
		}
		diagnosticCache = nil
		for view in views {
			view.needsDisplay = true
			view.gutter?.needsDisplay = true
			view.diagnosticStrip?.update()
		}
	}

	public var hasDiagnostics: Bool { !diagnosticMarks.isEmpty }

	/// A language server checks this document: editors reserve a column for the problem marks
	/// (kept while there are none, so the text does not shift as problems come and go).
	public var showsDiagnostics: Bool {
		get { diagnosticsShown }
		set {
			guard newValue != diagnosticsShown else { return }
			diagnosticsShown = newValue
			for view in views { view.diagnosticStrip?.update() }
		}
	}

	/// The problems where they are now, in text order (errors first at the same place).
	public var diagnostics: [EditorDiagnostic] {
		if let diagnosticCache, diagnosticCache.version == version { return diagnosticCache.items }
		let items = diagnosticMarks.compactMap { m -> EditorDiagnostic? in
			guard let lo = anchors.offset(of: m.start), let hi = anchors.offset(of: m.end) else { return nil }
			var d = m.diagnostic
			d.range = lo..<max(lo, hi)
			return d
		}.sorted { ($0.range.lowerBound, $0.severity) < ($1.range.lowerBound, $1.severity) }
		diagnosticCache = (version, items)
		return items
	}
}

extension EditorView {
	/// Problems touching `lines`.
	func diagnostics(lines: ClosedRange<Int>) -> [EditorDiagnostic] {
		let start = rope.offset(ofLine: lines.lowerBound), end = rope.lineRange(lines.upperBound).upperBound
		return document.diagnostics.filter { $0.range.lowerBound <= end && $0.range.upperBound >= start }
	}

	/// Wavy underlines below the baseline (dotted for hints); unused code is faded.
	func drawDiagnostics(_ ctx: CGContext, lines: ClosedRange<Int>) {
		// Hints first: errors are drawn over everything else.
		for d in diagnostics(lines: lines).sorted(by: { $0.severity > $1.severity }) {
			let rects = rangeRects(d.range, lines: lines)
			if d.unnecessary {
				ctx.setFillColor(NSColor.textBackgroundColor.withAlphaComponent(0.45).cgColor)
				for r in rects { ctx.fill(r) }
			}
			ctx.setStrokeColor(d.color.cgColor)
			ctx.setLineWidth(1)
			for var r in rects {
				// An empty range (a missing token) gets the width of a character.
				if r.width < 2 { r.size.width = newlineWidth }
				let y = r.minY + ascent + 2.5
				if d.severity == .hint {
					ctx.setLineDash(phase: 0, lengths: [1, 2])
					ctx.move(to: CGPoint(x: r.minX, y: y))
					ctx.addLine(to: CGPoint(x: r.maxX, y: y))
					ctx.strokePath()
					ctx.setLineDash(phase: 0, lengths: [])
					continue
				}
				ctx.move(to: CGPoint(x: r.minX, y: y + 1))
				var x = r.minX, up = true
				while x < r.maxX {
					x = min(x + 2, r.maxX)
					ctx.addLine(to: CGPoint(x: x, y: up ? y - 1 : y + 1))
					up.toggle()
				}
				ctx.strokePath()
			}
		}
	}

	static let diagnosticDotX: CGFloat = 10

	/// The most severe problem starting on each drawn line, as a dot left of its number.
	func drawDiagnosticMarks(_ ctx: CGContext, in rect: NSRect) {
		guard !document.diagnosticMarks.isEmpty else { return }
		let shown = lines(inY: rect.minY, rect.maxY)
		guard let first = shown.first, let last = shown.last else { return }
		let size = min(7, lineHeight - 4)
		for (line, d) in worstDiagnostics(lines: first...last) where !display.isHidden(line) {
			ctx.setFillColor(d.color.cgColor)
			let cy = y(ofLine: line) + lineHeight / 2
			ctx.fillEllipse(in: CGRect(x: Self.diagnosticDotX - size / 2, y: cy - size / 2, width: size, height: size))
		}
	}

	/// The narrowest problem whose underline is under `point` (also off words: a missing
	/// semicolon, an operator), so the message shows under the resting mouse.
	func diagnosticRange(at point: NSPoint) -> Range<Int>? {
		guard document.hasDiagnostics else { return nil }
		let line = line(atY: point.y)
		guard line < rope.lineCount else { return nil }
		return diagnostics(lines: line...line).filter { d in
			rangeRects(d.range, lines: line...line).contains { r in
				var r = r
				if r.width < 2 { r.size.width = newlineWidth }
				return r.contains(point)
			}
		}.min { $0.range.count < $1.range.count }?.range
	}

	/// The most severe problem by the line it starts on (hints have no dot).
	func worstDiagnostics(lines: ClosedRange<Int>) -> [Int: EditorDiagnostic] {
		var worst: [Int: EditorDiagnostic] = [:]
		for d in diagnostics(lines: lines) where d.severity != .hint {
			let line = rope.line(containing: d.range.lowerBound)
			guard lines.contains(line) else { continue }
			if let w = worst[line], w.severity <= d.severity { continue }
			worst[line] = d
		}
		return worst
	}

	/// The messages of the problems on a line, most severe first (gutter tooltip).
	func diagnosticMessages(line: Int) -> String? {
		let found = diagnostics(lines: line...line).filter { rope.line(containing: $0.range.lowerBound) == line && $0.severity != .hint }
		guard !found.isEmpty else { return nil }
		return found.sorted { $0.severity < $1.severity }.map(\.message).joined(separator: "\n")
	}

	/// Navigate › Next Problem (F2) / Previous Problem (⇧F2): the caret moves to the start of
	/// the next problem after the caret (around the end of the file); hints are skipped while
	/// there are other problems. Returns the problem, nil (and a beep) when there is none.
	@discardableResult
	public func goToDiagnostic(forward: Bool) -> EditorDiagnostic? {
		let all = document.diagnostics
		let shown = all.contains { $0.severity != .hint } ? all.filter { $0.severity != .hint } : all
		// One stop per place (several problems can start at the same offset).
		var stops: [EditorDiagnostic] = []
		for d in shown where stops.last?.range.lowerBound != d.range.lowerBound { stops.append(d) }
		let at = caret
		let target = forward ? (stops.first { $0.range.lowerBound > at } ?? stops.first)
			: (stops.last { $0.range.lowerBound < at } ?? stops.last)
		guard let target else {
			NSSound.beep()
			return nil
		}
		reveal(target.range.lowerBound..<target.range.lowerBound)
		return target
	}

	/// The caret goes to a problem clicked in the gutter or the strip.
	func activate(_ d: EditorDiagnostic) {
		reveal(d.range.lowerBound..<d.range.lowerBound)
		window?.makeFirstResponder(self)
		onDiagnosticActivated?(d)
	}
}

/// Marks of the problems along the right edge of the editor, over the whole file: a click
/// goes to one. A column of its own right of the clip view and the scroller (a right content
/// inset of the scroll view), shown while a language server checks the file.
@MainActor
public final class DiagnosticStripView: NSView {
	private weak var editor: EditorView?
	private var observers: [any NSObjectProtocol] = []
	static let width: CGFloat = 7
	static let markHeight: CGFloat = 3

	@discardableResult
	public static func install(for editor: EditorView) -> DiagnosticStripView? {
		guard let scroll = editor.enclosingScrollView else { return nil }
		let view = DiagnosticStripView(editor: editor)
		scroll.addSubview(view, positioned: .above, relativeTo: nil)
		editor.diagnosticStrip = view
		let clip = scroll.contentView
		clip.postsFrameChangedNotifications = true
		view.observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak view] _ in
			MainActor.assumeIsolated { view?.update() }
		})
		view.update()
		return view
	}

	private init(editor: EditorView) {
		self.editor = editor
		super.init(frame: .zero)
		isHidden = true
		setAccessibilityElement(false) // the Problems panel lists the same
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	isolated deinit {
		observers.forEach(NotificationCenter.default.removeObserver)
	}

	public override var isFlipped: Bool { true }

	/// Reserves the column (or gives it back) and fills it.
	func update() {
		guard let editor, let scroll = editor.enclosingScrollView else { return }
		let shown = editor.document.showsDiagnostics
		isHidden = !shown
		let inset: CGFloat = shown ? Self.width : 0
		if scroll.contentInsets.right != inset {
			scroll.automaticallyAdjustsContentInsets = false
			var insets = scroll.contentInsets
			insets.right = inset
			scroll.contentInsets = insets
			editor.updateSize()
		}
		guard shown else { return }
		let clip = scroll.contentView.frame
		let frame = NSRect(x: scroll.bounds.maxX - Self.width, y: clip.minY, width: Self.width, height: clip.height)
		if frame != self.frame { self.frame = frame }
		needsDisplay = true
		window?.invalidateCursorRects(for: self)
	}

	/// Marks with their problem, errors last (on top).
	private func marks() -> [(rect: CGRect, diagnostic: EditorDiagnostic)] {
		guard let editor else { return [] }
		let total = max(editor.bounds.height, 1), h = bounds.height - Self.markHeight
		return editor.document.diagnostics.filter { $0.severity != .hint }.sorted { $0.severity > $1.severity }.map { d in
			let line = editor.rope.line(containing: d.range.lowerBound)
			let y = (editor.y(ofLine: line) / total * h).rounded()
			return (CGRect(x: 1, y: y, width: bounds.width - 2, height: Self.markHeight), d)
		}
	}

	public override func draw(_ dirtyRect: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext else { return }
		for (rect, d) in marks() where rect.intersects(dirtyRect) {
			ctx.setFillColor(d.color.cgColor)
			ctx.fill(rect)
		}
	}

	private func mark(near point: NSPoint) -> EditorDiagnostic? {
		marks().filter { abs($0.rect.midY - point.y) <= 4 }.min { abs($0.rect.midY - point.y) < abs($1.rect.midY - point.y) }?.diagnostic
	}

	/// Only the marks take clicks; elsewhere the text below gets them.
	public override func hitTest(_ point: NSPoint) -> NSView? {
		guard !isHidden, let superview, frame.contains(point) else { return nil }
		return mark(near: convert(point, from: superview)) == nil ? nil : self
	}

	public override func mouseDown(with event: NSEvent) {
		guard let d = mark(near: convert(event.locationInWindow, from: nil)) else { return }
		editor?.activate(d)
	}

	public override func resetCursorRects() {
		for (rect, _) in marks() { addCursorRect(rect.insetBy(dx: 0, dy: -2), cursor: .pointingHand) }
	}
}
