import AppKit
import MinorCore
import Testing
import TextEngine
@testable import EditorKit

struct FoldRegionTests {
	let rope = Rope("func a() {\n\tif x {\n\t\ty()\n\n\t}\n\tz()\n}\n\nb")

	@Test func regionsByIndentation() {
		#expect(rope.foldRegion(headedBy: 0, tabWidth: 4) == 1...5)
		#expect(rope.foldRegion(headedBy: 1, tabWidth: 4) == 2...2)
		#expect(rope.foldRegion(headedBy: 2, tabWidth: 4) == nil)
		#expect(rope.isFoldHeader(1, tabWidth: 4) && !rope.isFoldHeader(5, tabWidth: 4))
		#expect(rope.allFoldRegions(tabWidth: 4).map(\.lines) == [1...5, 2...2])
		let mixed = Rope(" \t x\n\t\n  \n\ty")
		#expect(mixed.indentations(ofLines: 0..<mixed.lineCount, tabWidth: 4)
			== (0..<mixed.lineCount).map { mixed.indentation(ofLine: $0, tabWidth: 4) })
		#expect(mixed.indentations(ofLines: 0..<4, tabWidth: 4) == [5, nil, nil, 4])
	}

	@Test func displayMapRowsAndLines() {
		let map = DisplayMap(hidden: [2...3, 4...5, 8...8])
		#expect((0..<10).map(map.row(of:)) == [0, 1, 1, 1, 1, 1, 2, 3, 3, 4])
		#expect((0..<5).map(map.line(atRow:)) == [0, 1, 6, 7, 9])
		#expect(map.hiddenCount == 5 && map.isHidden(4) && !map.isHidden(6))
	}
}

@MainActor
struct FoldingTests {
	func editor() -> EditorView {
		let e = EditorView(text: "func a() {\n\tif x {\n\t\ty()\n\t}\n\tz()\n}\nb")
		var f = FormatSettings()
		f.indentStyle = .tab
		e.format = f
		return e
	}

	@Test func foldHidesLinesAndArrowsSkipThem() {
		let e = editor()
		e.moveCaret(to: 2)
		e.fold(nil)
		#expect(e.display.hidden == [1...4])
		#expect(e.rowCount == 3)
		#expect(e.caret == 2)
		e.doCommand(by: #selector(NSResponder.moveDown(_:)))
		#expect(e.rope.line(containing: e.caret) == 5)
		e.doCommand(by: #selector(NSResponder.moveUp(_:)))
		#expect(e.rope.line(containing: e.caret) == 0)
	}

	@Test func foldAgainTakesEnclosingRegion() {
		let e = editor()
		e.moveCaret(to: e.rope.offset(ofLine: 2) + 2)
		e.fold(nil)
		#expect(e.display.hidden == [2...2])
		#expect(e.rope.line(containing: e.caret) == 1)
		e.fold(nil)
		#expect(e.display.hidden == [1...4])
		e.unfold(nil)
		#expect(e.display.hidden == [2...2])
	}

	@Test func editsMoveFoldsAndEditsInsideUnfold() {
		let e = editor()
		e.foldAll(nil)
		#expect(e.folds.count == 2)
		e.moveCaret(to: e.rope.byteCount)
		e.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
		e.moveCaret(to: 0)
		e.insertText("// x\n", replacementRange: NSRange(location: NSNotFound, length: 0))
		#expect(e.display.hidden == [2...5])
		// Selecting text inside the fold (Find, undo) unfolds it.
		e.setSelections(SelectionSet(caret: e.rope.offset(ofLine: 5)))
		#expect(e.folds.count == 1)
		#expect(e.display.hidden == [3...3])
		e.unfoldAll(nil)
		#expect(e.display.isEmpty && e.rowCount == e.rope.lineCount)
	}

	@Test func backspaceBelowFoldUnfoldsInsteadOfHidingTheLine() {
		let e = editor()
		e.moveCaret(to: 0)
		e.fold(nil)
		e.moveCaret(to: e.rope.offset(ofLine: 5))
		e.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
		#expect(e.folds.isEmpty)
		#expect(e.rope.string.hasSuffix("\tz()}\nb"))
	}
}
