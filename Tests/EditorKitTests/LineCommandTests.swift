import AppKit
import MinorCore
import Testing
import TextEngine
@testable import EditorKit

@MainActor
struct LineCommandTests {
	@Test func duplicateMovesCaretsToCopy() {
		let e = EditorView(text: "ab\ncd\nef")
		e.setSelections(SelectionSet([Selection(caret: 1), Selection(caret: 8)]))
		e.duplicateLines(nil)
		#expect(e.rope.string == "ab\nab\ncd\nef\nef")
		#expect(e.selections.all.map(\.head) == [4, 14])
		e.undo(nil)
		#expect(e.rope.string == "ab\ncd\nef")
		#expect(e.selections.all.map(\.head) == [1, 8])
	}

	@Test func moveLinesKeepsSelectionAndStopsAtEdges() {
		let e = EditorView(text: "a\nbb\ncc\nd")
		// Selection over "bb" and "cc", ending at the start of "d" (which it does not include).
		e.setSelections(SelectionSet([Selection(anchor: 2, head: 8)]))
		e.moveLinesUp(nil)
		#expect(e.rope.string == "bb\ncc\na\nd")
		#expect(e.selections.primary == Selection(anchor: 0, head: 6))
		e.moveLinesUp(nil)
		#expect(e.rope.string == "bb\ncc\na\nd")
		e.moveLinesDown(nil)
		e.moveLinesDown(nil)
		#expect(e.rope.string == "a\nd\nbb\ncc")
		#expect(e.selections.primary == Selection(anchor: 4, head: 9))
		e.moveLinesDown(nil)
		#expect(e.rope.string == "a\nd\nbb\ncc")
		e.undo(nil)
		e.undo(nil)
		e.undo(nil)
		#expect(e.rope.string == "a\nbb\ncc\nd")
	}

	@Test func nextOccurrenceMatchesWholeWordsAndWraps() {
		let e = EditorView(text: "id idx id\nid")
		e.moveCaret(to: 7)
		e.selectNextOccurrence(nil)
		#expect(e.selections.all.map(\.range) == [7..<9])
		e.selectNextOccurrence(nil)
		e.selectNextOccurrence(nil)
		#expect(e.selections.all.map(\.range) == [0..<2, 7..<9, 10..<12])
		#expect(e.selections.primary.range == 0..<2)
		e.selectAllOccurrences(nil)
		#expect(e.selections.count == 3)
	}

	@Test func occurrencesOfPartialSelectionMatchInsideWords() {
		let e = EditorView(text: "idx id")
		e.setSelections(SelectionSet([Selection(anchor: 0, head: 2)]))
		e.selectAllOccurrences(nil)
		#expect(e.selections.all.map(\.range) == [0..<2, 4..<6])
	}

	@Test func convertIndentationBothWays() {
		let e = EditorView(text: "a\n\tb\n\t\t  c\n      d")
		var f = FormatSettings()
		f.indentStyle = .space
		f.indentSize = 4
		e.format = f
		e.convertIndentation(nil)
		#expect(e.rope.string == "a\n    b\n          c\n      d")
		f.indentStyle = .tab
		e.format = f
		e.convertIndentation(nil)
		#expect(e.rope.string == "a\n\tb\n\t\t  c\n\t  d")
	}
}

struct RopeSearchTests {
	@Test func findsAcrossChunksWithoutOverlaps() {
		let text = String(repeating: "x", count: (1 << 16) - 1) + "aaa" + "aa"
		let rope = Rope(text)
		#expect(rope.ranges(of: Array("aa".utf8)) == [65535..<65537, 65537..<65539])
		#expect(rope.nextRange(of: Array("aa".utf8), from: 65539) == 65535..<65537)
	}
}
