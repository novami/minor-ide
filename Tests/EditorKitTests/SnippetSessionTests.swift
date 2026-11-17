import AppKit
import Testing
import TextEngine
@testable import EditorKit

@MainActor
struct SnippetSessionTests {
	@Test func tabVisitsStopsAndUndoIsOneStep() {
		let e = EditorView(text: "package a\n\nfunc f() {\n\tfmt.Pr\n}\n")
		let start = e.rope.string.utf8.count - 5 // "Pr\n}\n"
		e.moveCaret(to: start + 2)
		e.insertSnippet(Snippet(parsing: "Printf(${1:format}, ${2:args})$0"), replacing: start..<(start + 2),
		                additionalEdits: [(11..<11, "import \"fmt\"\n\n")])
		#expect(e.rope.string == "package a\n\nimport \"fmt\"\n\nfunc f() {\n\tfmt.Printf(format, args)\n}\n")
		#expect(e.rope.string(in: e.selections.primary.range) == "format")
		e.doCommand(by: #selector(NSResponder.insertTab(_:)))
		#expect(e.rope.string(in: e.selections.primary.range) == "args")
		e.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
		#expect(e.rope.string(in: e.selections.primary.range) == "format")
		e.insertText("s", replacementRange: NSRange(location: NSNotFound, length: 0))
		e.doCommand(by: #selector(NSResponder.insertTab(_:)))
		e.doCommand(by: #selector(NSResponder.insertTab(_:)))
		#expect(!e.isInSnippet && e.caret == e.rope.string.utf8.count - 3)
		#expect(e.rope.string.contains("Printf(s, args)"))
		e.doCommand(by: #selector(NSResponder.insertTab(_:))) // a normal Tab again
		#expect(!e.rope.string.contains("Printf(s, args)\n")) // indentation went in
		e.undo(nil); e.undo(nil); e.undo(nil)
		#expect(e.rope.string == "package a\n\nfunc f() {\n\tfmt.Pr\n}\n")
	}

	@Test func indentFollowsLineAndEscEnds() {
		let e = EditorView(text: "\t\tx")
		e.moveCaret(to: 3)
		e.insertSnippet(Snippet(parsing: "if ${1:c} {\n\t$0\n}"), replacing: 2..<3)
		#expect(e.rope.string == "\t\tif c {\n\t\t\t\n\t\t}")
		e.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
		#expect(!e.isInSnippet)
	}

	@Test func everyCaretGetsTheSnippetAndLateEditsJoinTheUndoStep() {
		let e = EditorView(text: "a.Pr\nb.Pr\n")
		e.insertSnippet(Snippet(parsing: "Printf(${1:f})"), replacing: [2..<4, 7..<9])
		#expect(e.rope.string == "a.Printf(f)\nb.Printf(f)\n")
		#expect(e.selections.all.map { e.rope.string(in: $0.range) } == ["f", "f"])
		e.replaceJoiningUndo([(0..<0, "import x\n")])
		#expect(e.isInSnippet && e.selections.all.map { e.rope.string(in: $0.range) } == ["f", "f"])
		e.undo(nil)
		#expect(e.rope.string == "a.Pr\nb.Pr\n")
	}
}
