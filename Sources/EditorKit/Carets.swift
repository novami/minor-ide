import AppKit
import QuartzCore

/// Carets as one shape layer above the text. Moving them rebuilds a path; blinking is a
/// Core Animation opacity animation, so neither redraws text nor runs code per blink.
extension EditorView {
	func setUpCaretLayer() {
		caretLayer.anchorPoint = .zero
		caretLayer.actions = ["path": NSNull(), "opacity": NSNull(), "hidden": NSNull(), "fillColor": NSNull()]
		caretLayer.zPosition = 1
		layer?.addSublayer(caretLayer)
	}

	func setNeedsCaretUpdate() {
		caretsDirty = true
		// layout() rebuilds the path even when no text needs drawing.
		needsLayout = true
	}

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
		if let window {
			NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged), name: NSWindow.didBecomeKeyNotification, object: window)
			NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged), name: NSWindow.didResignKeyNotification, object: window)
		}
		setNeedsCaretUpdate()
	}

	@objc private func keyWindowChanged() {
		invalidate(selections) // selection colour follows the key window
		setNeedsCaretUpdate()
	}

	/// Carets show only in the focused editor of the key window, as in other macOS text views.
	var showsCarets: Bool {
		guard let window else { return false }
		return window.isKeyWindow && window.firstResponder === self
	}

	/// Rebuilds the caret path when carets moved or the visible lines left the covered range.
	func updateCaretsIfNeeded() {
		guard window != nil else { return } // offscreen drawing can report an unbounded visibleRect
		let visible = visibleRect.intersection(bounds)
		let first = line(atY: visible.minY)
		let last = min(rope.lineCount, line(atY: visible.maxY) + 1)
		if !caretsDirty && caretLines.lowerBound <= first && caretLines.upperBound >= last { return }
		caretsDirty = false
		// Carets one screen above and below are included, so short scrolls keep the path.
		let page = max(1, last - first)
		caretLines = max(0, first - page)..<min(rope.lineCount, last + page)
		let path = CGMutablePath()
		for rect in caretRects(lines: caretLines) { path.addRect(rect) }
		caretLayer.path = path
		effectiveAppearance.performAsCurrentDrawingAppearance { // dynamic colour for this view's appearance
			caretLayer.fillColor = NSColor.controlAccentColor.cgColor
		}
		caretLayer.isHidden = !showsCarets
		restartBlink()
	}

	/// Draws the carets into a context in view coordinates (snapshots).
	public func renderCarets(in ctx: CGContext) {
		updateCaretsIfNeeded()
		guard let path = caretLayer.path, let color = caretLayer.fillColor else { return }
		ctx.addPath(path)
		ctx.setFillColor(color)
		ctx.fillPath()
	}

	/// Caret rectangles of empty and non-empty selections whose head is on one of the lines.
	func caretRects(lines: Range<Int>) -> [CGRect] {
		var rects: [CGRect] = []
		for s in selections.all {
			let line = rope.line(containing: s.head)
			guard lines.contains(line) else { continue }
			rects.append(CGRect(x: x(of: s.head, line: line), y: y(ofLine: line) + 1, width: 2, height: lineHeight - 2))
		}
		return rects
	}

	/// The caret stays solid after each move and starts blinking after one "on" period.
	private func restartBlink() {
		caretLayer.removeAnimation(forKey: "blink")
		caretLayer.opacity = 1
		let defaults = UserDefaults.standard
		let on = (defaults.object(forKey: "NSTextInsertionPointBlinkPeriodOn") as? Double ?? 500) / 1000
		let off = (defaults.object(forKey: "NSTextInsertionPointBlinkPeriodOff") as? Double ?? 500) / 1000
		guard on > 0, off > 0, !caretLayer.isHidden else { return }
		let blink = CAKeyframeAnimation(keyPath: "opacity")
		blink.values = [1, 0]
		// Discrete animations need one key time more than values (ending at 1), else Core
		// Animation ignores them and the caret never blinks.
		blink.keyTimes = [0, NSNumber(value: on / (on + off)), 1]
		blink.calculationMode = .discrete
		blink.duration = on + off
		blink.repeatCount = .infinity
		blink.isRemovedOnCompletion = false
		caretLayer.add(blink, forKey: "blink")
	}
}
