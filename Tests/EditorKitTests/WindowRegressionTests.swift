import AppKit
import Testing
import TextEngine
@testable import EditorKit

/// Bugs found by hand in the running app, which offscreen snapshots did not show.
@MainActor
struct WindowRegressionTests {
	func editorInScrollView(width: CGFloat) -> (EditorView, NSScrollView) {
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
		scroll.hasVerticalScroller = true
		let e = EditorView(text: "a\nb")
		scroll.documentView = e
		GutterView.install(for: e)
		e.updateSize()
		scroll.frame = NSRect(x: 0, y: 0, width: width, height: 300)
		scroll.layoutSubtreeIfNeeded()
		return (e, scroll)
	}

	/// The editor was laid out at width 0 and never widened: the clip view does not resize it.
	@Test func editorWidthFollowsScrollView() {
		let (e, scroll) = editorInScrollView(width: 600)
		#expect(e.frame.width > 400)
		scroll.frame.size.width = 900
		scroll.layoutSubtreeIfNeeded()
		#expect(e.frame.width > 700)
	}

	/// Unclipped (macOS 14 default) the gutter's layer grew over the text and hid it.
	@Test func gutterAndEditorClipToBounds() {
		let (e, _) = editorInScrollView(width: 600)
		#expect(e.clipsToBounds)
		#expect(e.gutter?.clipsToBounds == true)
	}

	/// A discrete animation needs one key time more than values, else the caret never blinks.
	@Test func caretBlinkAnimationIsValid() throws {
		let e = EditorView(text: "x")
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
		window.contentView = e
		window.makeFirstResponder(e)
		e.updateCaretsIfNeeded()
		guard let blink = e.caretLayer.animation(forKey: "blink") as? CAKeyframeAnimation else { return } // hidden carets do not blink
		#expect(blink.keyTimes?.count == (blink.values?.count ?? 0) + 1)
	}
}
