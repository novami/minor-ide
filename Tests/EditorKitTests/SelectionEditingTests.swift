import AppKit
import Testing
import TextEngine
@testable import EditorKit

@MainActor
struct SelectionEditingTests {
	@Test func shiftArrowsExtendAndArrowsCollapse() {
		let e = EditorView(text: "ahoj\nsvěte")
		e.moveCaret(to: 1)
		e.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
		e.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
		#expect(e.selections.primary == Selection(anchor: 1, head: 3))
		e.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
		#expect(e.selections.primary.anchor == 1 && e.rope.line(containing: e.caret) == 1)
		e.doCommand(by: #selector(NSResponder.moveLeft(_:)))
		#expect(e.selections.primary == Selection(caret: 1))
	}

	@Test func typingReplacesEverySelection() {
		let e = EditorView(text: "ab\ncd\nef")
		e.setSelections(SelectionSet([Selection(caret: 1), Selection(anchor: 5, head: 3), Selection(caret: 8)]))
		e.insertText("č", replacementRange: NSRange(location: NSNotFound, length: 0))
		#expect(e.rope.string == "ačb\nč\nefč")
		#expect(e.selections.all.map(\.head) == [3, 7, 12])
		e.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
		#expect(e.rope.string == "ab\n\nef")
		e.doCommand(by: #selector(NSResponder.insertNewline(_:)))
		#expect(e.rope.string == "a\nb\n\n\nef\n")
	}

	@Test func adjacentCaretsMergeWhenDeleting() {
		let e = EditorView(text: "abc")
		e.setSelections(SelectionSet([Selection(caret: 2), Selection(caret: 3)]))
		e.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
		#expect(e.rope.string == "a")
		e.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
		#expect(e.rope.string == "")
		#expect(e.selections.count == 1)
	}

	@Test func escapeKeepsPrimaryOnly() {
		let e = EditorView(text: "abc")
		e.setSelections(SelectionSet([Selection(caret: 0), Selection(caret: 2)], primary: 0))
		e.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
		#expect(e.selections.all == [Selection(caret: 0)])
	}
}

@MainActor
struct SelectionDrawingTests {
	/// Draws a multi-line selection and two carets; selected text gets a different background.
	@Test func drawsSelection() throws {
		let e = EditorView(text: "ahoj světe\ndruhý řádek\ntřetí")
		e.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
		e.setSelections(SelectionSet([Selection(anchor: 2, head: 19), Selection(caret: 30)]))
		let rep = try #require(e.bitmapImageRepForCachingDisplay(in: e.bounds))
		e.cacheDisplay(in: e.bounds, to: rep)
		if let path = ProcessInfo.processInfo.environment["MINORIDE_SNAPSHOT"] {
			try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
		}
		// Line 2 is selected from its start; line 3 only holds a caret.
		let scale = CGFloat(rep.pixelsWide) / e.bounds.width
		func pixel(line: Int) -> NSColor? {
			rep.colorAt(x: Int((e.gutterWidth + e.textInset + 20) * scale), y: Int((CGFloat(line) + 0.5) * e.lineHeight * scale))
		}
		let inside = pixel(line: 1), outside = pixel(line: 2)
		#expect(inside != outside)
	}
}
