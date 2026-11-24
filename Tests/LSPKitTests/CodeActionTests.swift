import XCTest
@testable import MinorIDE

final class CodeActionTests: XCTestCase {
	func edit(_ line: Int, _ from: Int, _ to: Int, _ text: String) -> JSONValue {
		["range": ["start": ["line": .number(Double(line)), "character": .number(Double(from))],
		           "end": ["line": .number(Double(line)), "character": .number(Double(to))]],
		 "newText": .string(text)]
	}

	func testWorkspaceEditFromBothShapes() {
		let changes = WorkspaceEdit(["changes": ["file:///b.go": [edit(0, 0, 1, "x")], "file:///a.go": [edit(1, 0, 0, "y")]]])!
		XCTAssertEqual(changes.files.map(\.uri), ["file:///a.go", "file:///b.go"])
		XCTAssertTrue(changes.files.allSatisfy { $0.version == nil })
		// Entries of one file merge; a file operation is noted, not applied.
		let docs = WorkspaceEdit(["documentChanges": [
			["textDocument": ["uri": "file:///a.go", "version": 3], "edits": [edit(0, 0, 1, "x")]],
			["kind": "rename", "oldUri": "file:///a.go", "newUri": "file:///c.go"],
			["textDocument": ["uri": "file:///a.go", "version": 3], "edits": [edit(2, 0, 1, "z")]],
		]])!
		XCTAssertTrue(docs.files.count == 1 && docs.files[0].version == 3 && docs.editCount == 2)
		XCTAssertTrue(docs.hasFileOperations)
		XCTAssertNil(WorkspaceEdit(.null))
	}

	func testCodeActionsAndBareCommands() {
		let fix = CodeAction(["title": "Add import", "kind": "quickfix", "isPreferred": true,
		                      "edit": ["changes": ["file:///a.go": [edit(0, 0, 0, "import \"fmt\"\n")]]]])!
		XCTAssertTrue(fix.isQuickFix && fix.isPreferred && fix.edit?.editCount == 1 && fix.command == nil)
		let command = CodeAction(["title": "Run tests", "command": "gopls.test", "arguments": [1]])!
		XCTAssertTrue(command.command?["command"] == "gopls.test" && command.command?["arguments"] == [1] && command.edit == nil)
		let disabled = CodeAction(["title": "Extract", "kind": "refactor.extract", "disabled": ["reason": "select an expression"]])!
		XCTAssertTrue(disabled.disabledReason == "select an expression" && !disabled.isQuickFix)
	}

	func testEditsBecomeSortedReplacements() {
		let rope = Rope("ab\nčd\n")
		// UTF-16: "č" is one unit, two bytes.
		let edits = [TextEdit(edit(1, 1, 2, "D"))!, TextEdit(edit(0, 0, 1, "A"))!, TextEdit(edit(0, 0, 0, "<"))!]
		// An insertion goes before a replacement starting at the same place.
		let list = rope.replacements(edits, encoding: .utf16)!
		XCTAssertEqual(list.map(\.0), [0..<0, 0..<1, 5..<6])
		XCTAssertEqual(list.map(\.1), ["<", "A", "D"])
		XCTAssertNil(rope.replacements([TextEdit(edit(0, 0, 2, "x"))!, TextEdit(edit(0, 1, 2, "y"))!], encoding: .utf16))
	}

	func testLineSpanCoversWholeLines() {
		let rope = Rope("ab\ncd\nef")
		XCTAssertEqual(rope.lineSpan(of: 4..<4), 3..<6)
		// Ending at the start of a line does not take that line; the last line has no break.
		XCTAssertEqual(rope.lineSpan(of: 1..<6), 0..<6)
		XCTAssertEqual(rope.lineSpan(of: 4..<7), 3..<8)
	}

	func testPreviewShowsLinesAfterTheChange() {
		let rope = Rope("func old() {}\n\nx := old() + old()\n")
		let lines = rope.previewLines([(5..<8, "new"), (20..<23, "new"), (28..<31, "new")])
		XCTAssertEqual(lines.map(\.line), [0, 2])
		XCTAssertEqual(lines[0].text, "func new() {}")
		XCTAssertEqual(lines[1].text, "x := new() + new()")
		XCTAssertEqual(lines[1].ranges, [5..<8, 13..<16])
	}
}
