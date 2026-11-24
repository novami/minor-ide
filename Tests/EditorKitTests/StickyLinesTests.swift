import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class StickyLinesTests: XCTestCase {
	func testPinsEnclosingLinesWhileScrolling() {
		let body = (0..<60).map { "\t\tline\($0)()" }.joined(separator: "\n")
		let e = EditorView(text: "type T struct{}\nfunc f() {\n\tif x {\n\(body)\n\t}\n}\n")
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
		scroll.hasVerticalScroller = true
		scroll.documentView = e
		e.updateSize()
		let sticky = StickyLinesView.install(for: e)!
		XCTAssertTrue(sticky.isHidden) // the headers are on screen
		e.scroll(NSPoint(x: 0, y: 20 * e.lineHeight))
		sticky.update()
		XCTAssertTrue(sticky.lines == [1, 2] && !sticky.isHidden && sticky.frame.height == 2 * e.lineHeight)
		// Moving the caret up below the pinned rows scrolls it out from under them.
		e.moveCaret(to: e.rope.offset(ofLine: 22))
		e.doCommand(by: #selector(NSResponder.moveUp(_:)))
		XCTAssertTrue(e.y(ofLine: 21) >= e.visibleRect.minY + e.stickyHeight)
		EditorView.showsStickyLines = false
		defer { EditorView.showsStickyLines = true }
		XCTAssertTrue(sticky.isHidden)
	}
}
