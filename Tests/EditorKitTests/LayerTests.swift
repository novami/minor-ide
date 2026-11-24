import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class LayerTests {
	let e = EditorView(text: "foo\nbar baz\nqux\n")
	let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)

	init() {
		window.isReleasedWhenClosed = false
		let scroll = NSScrollView(frame: window.contentView!.bounds)
		scroll.documentView = e
		window.contentView = scroll
		GutterView.install(for: e)
		e.updateSize()
		window.makeKeyAndOrderFront(nil)
		window.makeFirstResponder(e)
	}

	/// Layout (caret path) and drawing of every dirty layer, as at the end of a run loop pass.
	func display() {
		window.displayIfNeeded()
		CATransaction.flush()
	}

	isolated deinit { window.close() }

	func testCaretsMoveInTheirLayerWithoutRedrawingText() throws {
		display()
		e.setSelections(SelectionSet([Selection(caret: 5), Selection(caret: 13)])) // "b|ar", "q|ux"
		display()
		let path = try XCTUnwrap(e.caretLayer.path)
		let width = ("0" as NSString).size(withAttributes: [.font: e.font]).width
		XCTAssertTrue(path.contains(CGPoint(x: e.textInset + width + 1, y: e.lineHeight * 1.5)))
		XCTAssertTrue(path.contains(CGPoint(x: e.textInset + width + 1, y: e.lineHeight * 2.5)))
		XCTAssertFalse(path.contains(CGPoint(x: e.textInset + 1, y: e.lineHeight * 0.5)))
		// A test process may not get a key window; blinking runs only while carets show.
		XCTAssertEqual((e.caretLayer.animation(forKey: "blink") != nil), e.showsCarets)

		// Blinking needs no draw pass at all.
		let draws = e.drawCount
		display()
		XCTAssertEqual(e.drawCount, draws)
	}

	func testCaretsHideWithoutFocus() {
		window.makeFirstResponder(nil)
		display()
		XCTAssertTrue(e.caretLayer.isHidden)
		window.makeFirstResponder(e)
		display()
		XCTAssertEqual(e.showsCarets, !e.caretLayer.isHidden)
	}

	func testGutterSitsBesideTextAndRedrawsOnlyWhenLinesChange() throws {
		let gutter = try XCTUnwrap(e.gutter)
		XCTAssertEqual(gutter.frame.width, e.gutterWidth)
		XCTAssertTrue(e.convert(NSPoint.zero, to: nil).x >= e.gutterWidth) // text starts right of the gutter
		e.setSelections(SelectionSet(caret: 3))
		display()
		var draws = gutter.drawCount
		e.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
		display()
		XCTAssertEqual(gutter.drawCount, draws) // same line numbers
		draws = gutter.drawCount
		e.doCommand(by: #selector(NSResponder.insertNewline(_:)))
		display()
		XCTAssertTrue(gutter.drawCount > draws)
	}

	func testLatencyMonitorTimesKeyToCommit() {
		let monitor = LatencyMonitor(view: e)
		e.latencyMonitor = monitor
		let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
		                           windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x",
		                           isARepeat: false, keyCode: 7)!
		e.keyDown(with: key)
		RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) // the pass ends with the commit
		XCTAssertEqual(e.rope.string(in: 0..<1), "x")
		XCTAssertEqual(monitor.commits.count, 1)
		XCTAssertTrue(monitor.commits.allSatisfy { $0 >= 0 && $0 < 1 })
	}

	func testAccessibilityReadsTheCurrentLine() {
		let e = EditorView(text: "Příliš\nžluťoučký kůň\n")
		e.setSelections(SelectionSet(caret: 12)) // bytes of "Příliš\nž"
		XCTAssertEqual(e.accessibilityRole(), .textArea)
		let line = e.accessibilityInsertionPointLineNumber()
		XCTAssertEqual(line, 1)
		XCTAssertEqual(e.accessibilityString(for: e.accessibilityRange(forLine: line)), "žluťoučký kůň\n")
		XCTAssertEqual(e.accessibilitySelectedTextRange(), NSRange(location: 8, length: 0))
		XCTAssertEqual(e.accessibilityLine(for: 8), 1)
		e.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 6))
		XCTAssertEqual(e.accessibilitySelectedText(), "Příliš")
		XCTAssertEqual(e.accessibilityNumberOfCharacters(), 21)
	}
}
