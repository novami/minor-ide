import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class MouseTests: XCTestCase {
	let e = EditorView(text: "foo bar_1(x)\n  baz\nqux quux\n")

	/// Point in the middle of a column of the monospace text.
	func at(_ column: Int, line: Int) -> NSPoint {
		let width = ("0" as NSString).size(withAttributes: [.font: e.font]).width
		return NSPoint(x: e.textInset + (CGFloat(column) + 0.4) * width, y: (CGFloat(line) + 0.5) * e.lineHeight)
	}

	func testDoubleClickSelectsWordAndDragExtendsByWords() {
		e.mouseDown(at: at(5, line: 0), clicks: 2, modifiers: [])
		XCTAssertEqual(e.selections.primary, Selection(anchor: 4, head: 9)) // "bar_1"
		e.mouseDragged(to: at(1, line: 0))
		XCTAssertEqual(e.selections.primary, Selection(anchor: 9, head: 0))
		e.mouseDragged(to: at(3, line: 1))
		XCTAssertEqual(e.selections.primary, Selection(anchor: 4, head: 18)) // through "baz"
	}

	func testTripleClickSelectsLines() {
		e.mouseDown(at: at(2, line: 1), clicks: 3, modifiers: [])
		XCTAssertEqual(e.selections.primary.range, 13..<19)
		e.mouseDragged(to: at(0, line: 2))
		XCTAssertEqual(e.selections.primary.range, 13..<28)
	}

	func testOptionDragSelectsColumn() {
		e.mouseDown(at: at(8, line: 2), clicks: 1, modifiers: [])
		e.mouseDown(at: at(1, line: 0), clicks: 1, modifiers: .option)
		e.mouseDragged(to: at(4, line: 2))
		let ranges = e.selections.all.map(\.range)
		XCTAssertEqual(ranges, [1..<4, 14..<17, 20..<23, 27..<27]) // the earlier caret is kept
		XCTAssertEqual(e.selections.primary.range, 20..<23)
	}

	/// Past the line end: that line's end; below the last row: the end of the text.
	func testClickOutsideTextGoesToNearestPosition() {
		e.mouseDown(at: at(40, line: 1), clicks: 1, modifiers: [])
		XCTAssertEqual(e.selections.primary.range, 18..<18) // after "  baz"
		e.mouseDown(at: NSPoint(x: e.textInset, y: 20 * e.lineHeight), clicks: 1, modifiers: [])
		XCTAssertEqual(e.selections.primary.range, 28..<28)
		let f = EditorView(text: "ab\ncd")
		f.mouseDown(at: NSPoint(x: f.textInset, y: 9 * f.lineHeight), clicks: 1, modifiers: [])
		XCTAssertEqual(f.selections.primary.range, 5..<5) // end of "cd", not its first column
	}

	func testWordRanges() {
		let r = Rope("a  b->c\n\nd")
		XCTAssertEqual(r.wordRange(at: 0), 0..<1)
		XCTAssertEqual(r.wordRange(at: 1), 1..<3)
		XCTAssertEqual(r.wordRange(at: 4), 4..<6)
		XCTAssertEqual(r.wordRange(at: 7), 6..<7) // line end takes the run before
		XCTAssertEqual(r.wordRange(at: 8), 8..<8) // empty line
	}
}

@MainActor
final class LinkTests: XCTestCase {
	let e = EditorView(text: "foo bar_1(x)\n  baz\n")

	func at(_ column: Int, line: Int) -> NSPoint {
		let width = ("0" as NSString).size(withAttributes: [.font: e.font]).width
		return NSPoint(x: e.textInset + (CGFloat(column) + 0.4) * width, y: (CGFloat(line) + 0.5) * e.lineHeight)
	}

	func testCommandClickNavigatesWithoutMovingTheCaret() {
		var clicked: [Int] = []
		e.mouseDown(at: at(1, line: 0), clicks: 1, modifiers: [.command, .shift])
		XCTAssertTrue(clicked.isEmpty) // no handler: an ordinary click
		e.onNavigate = { clicked.append($0); return true }
		e.setSelections(SelectionSet(caret: 0))
		e.mouseDown(at: at(5, line: 0), clicks: 1, modifiers: .command)
		XCTAssertEqual(clicked, [5])
		XCTAssertEqual(e.selections.primary, Selection(caret: 0))
		e.mouseDown(at: at(5, line: 0), clicks: 1, modifiers: [.command, .option])
		XCTAssertTrue(clicked == [5] && e.selections.all.count == 2) // ⌘⌥: not a jump
	}

	func testLinkWordIsAnIdentifierUnderTheMouse() {
		XCTAssertEqual(e.linkWord(at: at(5, line: 0)), 4..<9) // "bar_1"
		XCTAssertEqual(e.linkWord(at: at(9, line: 0)), nil) // "("
		XCTAssertEqual(e.linkWord(at: at(0, line: 1)), nil) // indentation
		XCTAssertEqual(e.linkWord(at: at(9, line: 1)), nil) // past the end of the line
		e.linkRange = 4..<9
		e.replace(0..<0, with: "x")
		XCTAssertEqual(e.linkRange, nil) // edits drop the link
	}
}
