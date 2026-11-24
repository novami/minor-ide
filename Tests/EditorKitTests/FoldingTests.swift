import AppKit
import XCTest
@testable import MinorIDE

final class FoldRegionTests: XCTestCase {
	let rope = Rope("func a() {\n\tif x {\n\t\ty()\n\n\t}\n\tz()\n}\n\nb")

	func testRegionsByIndentation() {
		XCTAssertEqual(rope.foldRegion(headedBy: 0, tabWidth: 4), 1...5)
		XCTAssertEqual(rope.foldRegion(headedBy: 1, tabWidth: 4), 2...2)
		XCTAssertNil(rope.foldRegion(headedBy: 2, tabWidth: 4))
		XCTAssertTrue(rope.isFoldHeader(1, tabWidth: 4) && !rope.isFoldHeader(5, tabWidth: 4))
		XCTAssertEqual(rope.allFoldRegions(tabWidth: 4).map(\.lines), [1...5, 2...2])
		let mixed = Rope(" \t x\n\t\n  \n\ty")
		XCTAssertEqual(mixed.indentations(ofLines: 0..<mixed.lineCount, tabWidth: 4), (0..<mixed.lineCount).map { mixed.indentation(ofLine: $0, tabWidth: 4) })
		XCTAssertEqual(mixed.indentations(ofLines: 0..<4, tabWidth: 4), [5, nil, nil, 4])
	}

	func testDisplayMapRowsAndLines() {
		let map = DisplayMap(hidden: [2...3, 4...5, 8...8])
		XCTAssertEqual((0..<10).map(map.row(of:)), [0, 1, 1, 1, 1, 1, 2, 3, 3, 4])
		XCTAssertEqual((0..<5).map(map.line(atRow:)), [0, 1, 6, 7, 9])
		XCTAssertTrue(map.hiddenCount == 5 && map.isHidden(4) && !map.isHidden(6))
	}
}

@MainActor
final class FoldingTests: XCTestCase {
	func editor() -> EditorView {
		let e = EditorView(text: "func a() {\n\tif x {\n\t\ty()\n\t}\n\tz()\n}\nb")
		var f = FormatSettings()
		f.indentStyle = .tab
		e.format = f
		return e
	}

	func testFoldHidesLinesAndArrowsSkipThem() {
		let e = editor()
		e.moveCaret(to: 2)
		e.fold(nil)
		XCTAssertEqual(e.display.hidden, [1...4])
		XCTAssertEqual(e.rowCount, 3)
		XCTAssertEqual(e.caret, 2)
		e.doCommand(by: #selector(NSResponder.moveDown(_:)))
		XCTAssertEqual(e.rope.line(containing: e.caret), 5)
		e.doCommand(by: #selector(NSResponder.moveUp(_:)))
		XCTAssertEqual(e.rope.line(containing: e.caret), 0)
	}

	func testFoldAgainTakesEnclosingRegion() {
		let e = editor()
		e.moveCaret(to: e.rope.offset(ofLine: 2) + 2)
		e.fold(nil)
		XCTAssertEqual(e.display.hidden, [2...2])
		XCTAssertEqual(e.rope.line(containing: e.caret), 1)
		e.fold(nil)
		XCTAssertEqual(e.display.hidden, [1...4])
		e.unfold(nil)
		XCTAssertEqual(e.display.hidden, [2...2])
	}

	func testEditsMoveFoldsAndEditsInsideUnfold() {
		let e = editor()
		e.foldAll(nil)
		XCTAssertEqual(e.folds.count, 2)
		e.moveCaret(to: e.rope.byteCount)
		e.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
		e.moveCaret(to: 0)
		e.insertText("// x\n", replacementRange: NSRange(location: NSNotFound, length: 0))
		XCTAssertEqual(e.display.hidden, [2...5])
		// Selecting text inside the fold (Find, undo) unfolds it.
		e.setSelections(SelectionSet(caret: e.rope.offset(ofLine: 5)))
		XCTAssertEqual(e.folds.count, 1)
		XCTAssertEqual(e.display.hidden, [3...3])
		e.unfoldAll(nil)
		XCTAssertTrue(e.display.isEmpty && e.rowCount == e.rope.lineCount)
	}

	func testBackspaceBelowFoldUnfoldsInsteadOfHidingTheLine() {
		let e = editor()
		e.moveCaret(to: 0)
		e.fold(nil)
		e.moveCaret(to: e.rope.offset(ofLine: 5))
		e.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
		XCTAssertTrue(e.folds.isEmpty)
		XCTAssertTrue(e.rope.string.hasSuffix("\tz()}\nb"))
	}
}
