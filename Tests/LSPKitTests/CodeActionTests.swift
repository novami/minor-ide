import Testing
import MinorCore
import TextEngine
@testable import LSPKit

struct CodeActionTests {
	func edit(_ line: Int, _ from: Int, _ to: Int, _ text: String) -> JSONValue {
		["range": ["start": ["line": .number(Double(line)), "character": .number(Double(from))],
		           "end": ["line": .number(Double(line)), "character": .number(Double(to))]],
		 "newText": .string(text)]
	}

	@Test func workspaceEditFromBothShapes() {
		let changes = WorkspaceEdit(["changes": ["file:///b.go": [edit(0, 0, 1, "x")], "file:///a.go": [edit(1, 0, 0, "y")]]])!
		#expect(changes.files.map(\.uri) == ["file:///a.go", "file:///b.go"])
		#expect(changes.files.allSatisfy { $0.version == nil })
		// Entries of one file merge; a file operation is noted, not applied.
		let docs = WorkspaceEdit(["documentChanges": [
			["textDocument": ["uri": "file:///a.go", "version": 3], "edits": [edit(0, 0, 1, "x")]],
			["kind": "rename", "oldUri": "file:///a.go", "newUri": "file:///c.go"],
			["textDocument": ["uri": "file:///a.go", "version": 3], "edits": [edit(2, 0, 1, "z")]],
		]])!
		#expect(docs.files.count == 1 && docs.files[0].version == 3 && docs.editCount == 2)
		#expect(docs.hasFileOperations)
		#expect(WorkspaceEdit(.null) == nil)
	}

	@Test func codeActionsAndBareCommands() {
		let fix = CodeAction(["title": "Add import", "kind": "quickfix", "isPreferred": true,
		                      "edit": ["changes": ["file:///a.go": [edit(0, 0, 0, "import \"fmt\"\n")]]]])!
		#expect(fix.isQuickFix && fix.isPreferred && fix.edit?.editCount == 1 && fix.command == nil)
		let command = CodeAction(["title": "Run tests", "command": "gopls.test", "arguments": [1]])!
		#expect(command.command?["command"] == "gopls.test" && command.command?["arguments"] == [1] && command.edit == nil)
		let disabled = CodeAction(["title": "Extract", "kind": "refactor.extract", "disabled": ["reason": "select an expression"]])!
		#expect(disabled.disabledReason == "select an expression" && !disabled.isQuickFix)
	}

	@Test func editsBecomeSortedReplacements() {
		let rope = Rope("ab\nčd\n")
		// UTF-16: "č" is one unit, two bytes.
		let edits = [TextEdit(edit(1, 1, 2, "D"))!, TextEdit(edit(0, 0, 1, "A"))!, TextEdit(edit(0, 0, 0, "<"))!]
		// An insertion goes before a replacement starting at the same place.
		let list = rope.replacements(edits, encoding: .utf16)!
		#expect(list.map(\.0) == [0..<0, 0..<1, 5..<6])
		#expect(list.map(\.1) == ["<", "A", "D"])
		#expect(rope.replacements([TextEdit(edit(0, 0, 2, "x"))!, TextEdit(edit(0, 1, 2, "y"))!], encoding: .utf16) == nil)
	}

	@Test func previewShowsLinesAfterTheChange() {
		let rope = Rope("func old() {}\n\nx := old() + old()\n")
		let lines = rope.previewLines([(5..<8, "new"), (20..<23, "new"), (28..<31, "new")])
		#expect(lines.map(\.line) == [0, 2])
		#expect(lines[0].text == "func new() {}")
		#expect(lines[1].text == "x := new() + new()")
		#expect(lines[1].ranges == [5..<8, 13..<16])
	}
}
