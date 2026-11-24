import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class LineCommandTests: XCTestCase {
	func testDuplicateMovesCaretsToCopy() {
		let e = EditorView(text: "ab\ncd\nef")
		e.setSelections(SelectionSet([Selection(caret: 1), Selection(caret: 8)]))
		e.duplicateLines(nil)
		XCTAssertEqual(e.rope.string, "ab\nab\ncd\nef\nef")
		XCTAssertEqual(e.selections.all.map(\.head), [4, 14])
		e.undo(nil)
		XCTAssertEqual(e.rope.string, "ab\ncd\nef")
		XCTAssertEqual(e.selections.all.map(\.head), [1, 8])
	}

	func testMoveLinesKeepsSelectionAndStopsAtEdges() {
		let e = EditorView(text: "a\nbb\ncc\nd")
		// Selection over "bb" and "cc", ending at the start of "d" (which it does not include).
		e.setSelections(SelectionSet([Selection(anchor: 2, head: 8)]))
		e.moveLinesUp(nil)
		XCTAssertEqual(e.rope.string, "bb\ncc\na\nd")
		XCTAssertEqual(e.selections.primary, Selection(anchor: 0, head: 6))
		e.moveLinesUp(nil)
		XCTAssertEqual(e.rope.string, "bb\ncc\na\nd")
		e.moveLinesDown(nil)
		e.moveLinesDown(nil)
		XCTAssertEqual(e.rope.string, "a\nd\nbb\ncc")
		XCTAssertEqual(e.selections.primary, Selection(anchor: 4, head: 9))
		e.moveLinesDown(nil)
		XCTAssertEqual(e.rope.string, "a\nd\nbb\ncc")
		e.undo(nil)
		e.undo(nil)
		e.undo(nil)
		XCTAssertEqual(e.rope.string, "a\nbb\ncc\nd")
	}

	func testNextOccurrenceMatchesWholeWordsAndWraps() {
		let e = EditorView(text: "id idx id\nid")
		e.moveCaret(to: 7)
		e.selectNextOccurrence(nil)
		XCTAssertEqual(e.selections.all.map(\.range), [7..<9])
		e.selectNextOccurrence(nil)
		e.selectNextOccurrence(nil)
		XCTAssertEqual(e.selections.all.map(\.range), [0..<2, 7..<9, 10..<12])
		XCTAssertEqual(e.selections.primary.range, 0..<2)
		e.selectAllOccurrences(nil)
		XCTAssertEqual(e.selections.count, 3)
	}

	func testOccurrencesOfPartialSelectionMatchInsideWords() {
		let e = EditorView(text: "idx id")
		e.setSelections(SelectionSet([Selection(anchor: 0, head: 2)]))
		e.selectAllOccurrences(nil)
		XCTAssertEqual(e.selections.all.map(\.range), [0..<2, 4..<6])
	}

	func testConvertIndentationBothWays() {
		let e = EditorView(text: "a\n\tb\n\t\t  c\n      d")
		var f = FormatSettings()
		f.indentStyle = .space
		f.indentSize = 4
		e.format = f
		e.convertIndentation(nil)
		XCTAssertEqual(e.rope.string, "a\n    b\n          c\n      d")
		f.indentStyle = .tab
		e.format = f
		e.convertIndentation(nil)
		XCTAssertEqual(e.rope.string, "a\n\tb\n\t\t  c\n\t  d")
	}
}

final class RopeSearchTests: XCTestCase {
	func testFindsAcrossChunksWithoutOverlaps() {
		let text = String(repeating: "x", count: (1 << 16) - 1) + "aaa" + "aa"
		let rope = Rope(text)
		XCTAssertEqual(rope.ranges(of: Array("aa".utf8)), [65535..<65537, 65537..<65539])
		XCTAssertEqual(rope.nextRange(of: Array("aa".utf8), from: 65539), 65535..<65537)
	}
}
