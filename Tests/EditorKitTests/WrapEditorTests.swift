import AppKit
import MinorCore
import Testing
import TextEngine
@testable import EditorKit

/// The switch is global; tests on the main actor run one at a time and switch it back.
@MainActor
struct WrapEditorTests {
	func wrapped(_ text: String) -> EditorView {
		let e = EditorView(text: text)
		var f = FormatSettings()
		f.maxLineLength = 10
		e.format = f
		EditorView.wrapsLines = true
		return e
	}

	func at(_ e: EditorView, _ column: Int, row: Int) -> NSPoint {
		let width = ("0" as NSString).size(withAttributes: [.font: e.font]).width
		return NSPoint(x: e.textInset + (CGFloat(column) + 0.4) * width, y: (CGFloat(row) + 0.5) * e.lineHeight)
	}

	@Test func rowsCaretsAndMoves() {
		let e = wrapped("aaaa bbbb cccc\nx")
		defer { EditorView.wrapsLines = false }
		#expect(e.rowCount == 3 && e.wraps?.breaks(ofLine: 0) == [10])
		#expect(e.point(of: 10, line: 0) == CGPoint(x: e.textInset, y: e.lineHeight)) // the break starts row 2
		e.moveCaret(to: 2)
		e.doCommand(by: #selector(NSResponder.moveDown(_:)))
		#expect(e.caret == 12)
		e.doCommand(by: #selector(NSResponder.moveDown(_:)))
		#expect(e.caret == 16) // "x" is shorter: its end
		e.moveCaret(to: 2)
		e.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
		#expect(e.caret == 9) // before the break, so the caret stays on the row
		e.doCommand(by: #selector(NSResponder.moveToEndOfParagraph(_:)))
		#expect(e.caret == 14)
		e.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
		#expect(e.caret == 10)
		e.mouseDown(at: at(e, 2, row: 1), clicks: 1, modifiers: [])
		#expect(e.caret == 12)
		e.mouseDown(at: at(e, 8, row: 0), clicks: 1, modifiers: [])
		#expect(e.caret == 8)
	}

	@Test func editsChangeRowsAndSwitchOff() {
		let e = wrapped("aaaa bbbb cccc\nx")
		defer { EditorView.wrapsLines = false }
		e.moveCaret(to: 14)
		e.insertText(" ddddddd", replacementRange: NSRange(location: NSNotFound, length: 0))
		#expect(e.rowCount == 4 && e.wraps?.breaks(ofLine: 0) == [10, 15])
		e.moveCaret(to: 0)
		e.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
		#expect(e.rowCount == 5 && e.wraps?.lines == [1])
		e.undo(nil)
		e.undo(nil)
		#expect(e.rowCount == 3)
		EditorView.wrapsLines = false
		#expect(e.wraps == nil && e.rowCount == 2)
	}

	@Test func foldsAndWrapsTogether() {
		let e = wrapped("a {\n\tbbbb cccc dddd\n}\neeee ffff gggg")
		defer { EditorView.wrapsLines = false }
		#expect(e.rowCount == 6)
		e.setFolds([e.foldRange(headedBy: 0)!])
		#expect(e.rowCount == 4 && e.line(atY: e.lineHeight * 2.5) == 3)
	}

	@Test func unwrappedLinesScrollHorizontally() {
		let e = EditorView(text: "short\n")
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
		scroll.hasHorizontalScroller = true
		scroll.documentView = e
		e.updateSize()
		let narrow = e.frame.width
		e.moveCaret(to: 0)
		e.insertText(String(repeating: "x", count: 200), replacementRange: NSRange(location: NSNotFound, length: 0))
		#expect(e.document.maxColumns == 205 && e.frame.width > narrow * 3)
		#expect(e.visibleRect.minX > 0) // followed the caret to the right
		e.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
		#expect(e.visibleRect.minX == 0)
		var f = FormatSettings()
		f.maxLineLength = 20
		e.format = f
		EditorView.wrapsLines = true
		defer { EditorView.wrapsLines = false }
		#expect(e.frame.width == scroll.contentSize.width) // wrapped at 20 columns: fits the window
	}
}
