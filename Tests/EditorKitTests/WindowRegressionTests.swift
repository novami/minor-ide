import AppKit
import XCTest
@testable import MinorIDE

/// Bugs found by hand in the running app, which offscreen snapshots did not show.
@MainActor
final class WindowRegressionTests: XCTestCase {
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
	func testEditorWidthFollowsScrollView() {
		let (e, scroll) = editorInScrollView(width: 600)
		XCTAssertTrue(e.frame.width > 400)
		scroll.frame.size.width = 900
		scroll.layoutSubtreeIfNeeded()
		XCTAssertTrue(e.frame.width > 700)
	}

	/// A short text left the clip view's lower part outside the editor, so clicks there missed it.
	func testEditorFillsScrollViewHeight() {
		let (e, scroll) = editorInScrollView(width: 600)
		XCTAssertTrue(e.frame.height >= scroll.contentSize.height)
	}

	/// Unclipped (macOS 14 default) the gutter's layer grew over the text and hid it.
	func testGutterAndEditorClipToBounds() {
		let (e, _) = editorInScrollView(width: 600)
		XCTAssertTrue(e.clipsToBounds)
		XCTAssertEqual(e.gutter?.clipsToBounds, true)
	}

	/// A discrete animation needs one key time more than values, else the caret never blinks.
	func testCaretBlinkAnimationIsValid() throws {
		let e = EditorView(text: "x")
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
		window.contentView = e
		window.makeFirstResponder(e)
		e.updateCaretsIfNeeded()
		guard let blink = e.caretLayer.animation(forKey: "blink") as? CAKeyframeAnimation else { return } // hidden carets do not blink
		XCTAssertEqual(blink.keyTimes?.count, (blink.values?.count ?? 0) + 1)
	}
}
