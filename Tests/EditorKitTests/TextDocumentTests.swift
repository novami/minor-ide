import AppKit
import Testing
import TextEngine
@testable import EditorKit

/// Two editors of one document (split view).
@MainActor
struct TextDocumentTests {
	@Test func readOnlyRefusesEditsButSelectsAndCopies() {
		let a = EditorView(text: "abc")
		a.document.isReadOnly = true
		a.setSelections(SelectionSet([Selection(anchor: 0, head: 3)]))
		a.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
		a.setMarkedText("ˇ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
		a.cut(nil)
		#expect(a.rope.string == "abc")
		#expect(!a.hasMarkedText())
		#expect(!a.history.canUndo)
		let cut = NSMenuItem(title: "", action: #selector(EditorView.cut(_:)), keyEquivalent: "")
		let copy = NSMenuItem(title: "", action: #selector(EditorView.copy(_:)), keyEquivalent: "")
		#expect(!a.validateMenuItem(cut) && a.validateMenuItem(copy))
	}

	/// What a language server gets: every change (undo included) replayed on the old text gives
	/// the new one, with increasing versions.
	@Test func textEditsReplayToTheSameText() {
		let a = EditorView(text: "a\nb")
		var mirror = a.rope, versions: [Int] = []
		a.document.onTextEdit = { changes, rope, version in
			changes.apply(to: &mirror)
			#expect(mirror.string == rope.string)
			versions.append(version)
		}
		a.setSelections(SelectionSet(caret: 1))
		a.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
		a.replace([(0..<1, "č"), (3..<4, "")])
		a.undo(nil)
		#expect(mirror.string == a.rope.string && versions == [1, 2, 3])
	}

	@Test func editsUndoAndFoldsFollowAcrossPanes() {
		let a = EditorView(text: "func f() {\n\tx\n}\nend")
		let b = EditorView(document: a.document)
		var changes = 0
		a.document.onChange = { changes += 1 }
		b.setSelections(SelectionSet(caret: 17)) // before "end"
		a.setSelections(SelectionSet(caret: 0))
		a.insertText("// ", replacementRange: NSRange(location: NSNotFound, length: 0))
		#expect(b.rope.string == "// func f() {\n\tx\n}\nend")
		#expect(b.selections.primary.head == 20) // still before "end"
		#expect(changes == 1)

		b.undo(nil) // one history for both panes
		#expect(a.rope.string == "func f() {\n\tx\n}\nend")
		#expect(a.selections.primary.head == 0)

		b.setFolds([b.foldRange(headedBy: 0)!])
		let c = EditorView(document: a.document)
		c.adoptViewState(of: b)
		#expect(c.folds == b.folds)
		#expect(a.folds.isEmpty) // folds belong to a pane
		#expect(a.document.views.count == 3)
	}
}
