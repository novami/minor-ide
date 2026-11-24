import AppKit
import XCTest
@testable import MinorIDE

/// Two editors of one document (split view).
@MainActor
final class TextDocumentTests: XCTestCase {
	func testReadOnlyRefusesEditsButSelectsAndCopies() {
		let a = EditorView(text: "abc")
		a.document.isReadOnly = true
		a.setSelections(SelectionSet([Selection(anchor: 0, head: 3)]))
		a.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
		a.setMarkedText("ˇ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
		a.cut(nil)
		XCTAssertEqual(a.rope.string, "abc")
		XCTAssertFalse(a.hasMarkedText())
		XCTAssertFalse(a.history.canUndo)
		let cut = NSMenuItem(title: "", action: #selector(EditorView.cut(_:)), keyEquivalent: "")
		let copy = NSMenuItem(title: "", action: #selector(EditorView.copy(_:)), keyEquivalent: "")
		XCTAssertTrue(!a.validateMenuItem(cut) && a.validateMenuItem(copy))
	}

	/// What a language server gets: every change (undo included) replayed on the old text gives
	/// the new one, with increasing versions.
	func testTextEditsReplayToTheSameText() {
		let a = EditorView(text: "a\nb")
		var mirror = a.rope, versions: [Int] = []
		a.document.onTextEdit = { changes, rope, version in
			changes.apply(to: &mirror)
			XCTAssertEqual(mirror.string, rope.string)
			versions.append(version)
		}
		a.setSelections(SelectionSet(caret: 1))
		a.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
		a.replace([(0..<1, "č"), (3..<4, "")])
		a.undo(nil)
		XCTAssertTrue(mirror.string == a.rope.string && versions == [1, 2, 3])
	}

	func testEditsUndoAndFoldsFollowAcrossPanes() {
		let a = EditorView(text: "func f() {\n\tx\n}\nend")
		let b = EditorView(document: a.document)
		var changes = 0
		a.document.onChange = { changes += 1 }
		b.setSelections(SelectionSet(caret: 17)) // before "end"
		a.setSelections(SelectionSet(caret: 0))
		a.insertText("// ", replacementRange: NSRange(location: NSNotFound, length: 0))
		XCTAssertEqual(b.rope.string, "// func f() {\n\tx\n}\nend")
		XCTAssertEqual(b.selections.primary.head, 20) // still before "end"
		XCTAssertEqual(changes, 1)

		b.undo(nil) // one history for both panes
		XCTAssertEqual(a.rope.string, "func f() {\n\tx\n}\nend")
		XCTAssertEqual(a.selections.primary.head, 0)

		b.setFolds([b.foldRange(headedBy: 0)!])
		let c = EditorView(document: a.document)
		c.adoptViewState(of: b)
		XCTAssertEqual(c.folds, b.folds)
		XCTAssertTrue(a.folds.isEmpty) // folds belong to a pane
		XCTAssertEqual(a.document.views.count, 3)
	}
}
