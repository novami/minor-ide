import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class SelectionEditingTests: XCTestCase {
	func testShiftArrowsExtendAndArrowsCollapse() {
		let e = EditorView(text: "ahoj\nsvěte")
		e.moveCaret(to: 1)
		e.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
		e.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
		XCTAssertEqual(e.selections.primary, Selection(anchor: 1, head: 3))
		e.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
		XCTAssertTrue(e.selections.primary.anchor == 1 && e.rope.line(containing: e.caret) == 1)
		e.doCommand(by: #selector(NSResponder.moveLeft(_:)))
		XCTAssertEqual(e.selections.primary, Selection(caret: 1))
	}

	func testTypingReplacesEverySelection() {
		let e = EditorView(text: "ab\ncd\nef")
		e.setSelections(SelectionSet([Selection(caret: 1), Selection(anchor: 5, head: 3), Selection(caret: 8)]))
		e.insertText("č", replacementRange: NSRange(location: NSNotFound, length: 0))
		XCTAssertEqual(e.rope.string, "ačb\nč\nefč")
		XCTAssertEqual(e.selections.all.map(\.head), [3, 7, 12])
		e.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
		XCTAssertEqual(e.rope.string, "ab\n\nef")
		e.doCommand(by: #selector(NSResponder.insertNewline(_:)))
		XCTAssertEqual(e.rope.string, "a\nb\n\n\nef\n")
	}

	func testAdjacentCaretsMergeWhenDeleting() {
		let e = EditorView(text: "abc")
		e.setSelections(SelectionSet([Selection(caret: 2), Selection(caret: 3)]))
		e.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
		XCTAssertEqual(e.rope.string, "a")
		e.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
		XCTAssertEqual(e.rope.string, "")
		XCTAssertEqual(e.selections.count, 1)
	}

	func testEscapeKeepsPrimaryOnly() {
		let e = EditorView(text: "abc")
		e.setSelections(SelectionSet([Selection(caret: 0), Selection(caret: 2)], primary: 0))
		e.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
		XCTAssertEqual(e.selections.all, [Selection(caret: 0)])
	}
}

@MainActor
final class SelectionDrawingTests: XCTestCase {
	/// Draws a multi-line selection and two carets; selected text gets a different background.
	func testDrawsSelection() throws {
		let e = EditorView(text: "ahoj světe\ndruhý řádek\ntřetí")
		e.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
		e.setSelections(SelectionSet([Selection(anchor: 2, head: 19), Selection(caret: 30)]))
		let rep = try XCTUnwrap(e.bitmapImageRepForCachingDisplay(in: e.bounds))
		e.cacheDisplay(in: e.bounds, to: rep)
		if let path = ProcessInfo.processInfo.environment["MINORIDE_SNAPSHOT"] {
			try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
		}
		// Line 2 is selected from its start; line 3 only holds a caret.
		let scale = CGFloat(rep.pixelsWide) / e.bounds.width
		func pixel(line: Int) -> NSColor? {
			rep.colorAt(x: Int((e.textInset + 20) * scale), y: Int((CGFloat(line) + 0.5) * e.lineHeight * scale))
		}
		let inside = pixel(line: 1), outside = pixel(line: 2)
		XCTAssertNotEqual(inside, outside)
	}
}

@MainActor
final class UndoEditingTests: XCTestCase {
	private func type(_ e: EditorView, _ s: String) {
		for c in s { e.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) }
	}

	func testUndoRestoresTextAndCarets() {
		let e = EditorView(text: "ab\ncd")
		e.setSelections(SelectionSet([Selection(caret: 1), Selection(caret: 4)]))
		type(e, "xy z")
		XCTAssertEqual(e.rope.string, "axy zb\ncxy zd")
		e.undo(nil)
		XCTAssertEqual(e.rope.string, "axy b\ncxy d")
		e.undo(nil)
		XCTAssertEqual(e.rope.string, "ab\ncd")
		XCTAssertEqual(e.selections.all.map(\.head), [1, 4])
		e.redo(nil)
		e.redo(nil)
		XCTAssertEqual(e.rope.string, "axy zb\ncxy zd")
		XCTAssertEqual(e.selections.all.map(\.head), [5, 12])
		XCTAssertFalse(e.history.canRedo)
	}

	func testCutCopiesAndRemovesSelections() {
		let e = EditorView(text: "ahoj světe")
		e.setSelections(SelectionSet([Selection(anchor: 0, head: 4), Selection(anchor: 5, head: 11)]))
		e.cut(nil)
		XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ahoj\nsvěte")
		XCTAssertEqual(e.rope.string, " ")
		e.undo(nil)
		XCTAssertEqual(e.rope.string, "ahoj světe")
		e.selectAll(nil)
		XCTAssertEqual(e.selections.primary.range, 0..<e.rope.byteCount)
	}
}
