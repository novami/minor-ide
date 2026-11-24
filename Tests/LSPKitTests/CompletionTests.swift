import XCTest
@testable import MinorIDE

final class CompletionTests: XCTestCase {
	func testListWithDefaultsAndResolve() {
		let json: JSONValue = [
			"isIncomplete": true,
			"itemDefaults": ["insertTextFormat": 2, "editRange": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 5]]],
			"items": [
				["label": "Println", "kind": 3, "insertText": "Println(${1:})", "sortText": "b", "documentation": ["kind": "plaintext", "value": "prints"]],
				["label": "Printf", "kind": 3, "sortText": "a", "textEdit": ["range": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 5]], "newText": "Printf"],
				 "insertTextFormat": 1, "additionalTextEdits": [["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 0]], "newText": "import \"fmt\"\n"]]],
				["label": "Errorf", "kind": 3, "tags": [1]],
			],
		]
		let list = CompletionList(json)
		XCTAssertTrue(list.isIncomplete && list.items.count == 3)
		let a = list.items[0], b = list.items[1]
		XCTAssertTrue(a.isSnippet && a.snippet.text == "Println()" && a.documentation == "prints")
		XCTAssertEqual(a.range, LSPRange(start: Position(line: 0, character: 4), end: Position(line: 0, character: 5)))
		XCTAssertTrue(!b.isSnippet && b.additionalTextEdits.count == 1 && list.items[2].deprecated)
		var c = list.items[2]
		c.merge(resolved: ["label": "Errorf", "detail": "func(format string) error"])
		XCTAssertTrue(c.resolved && c.detail == "func(format string) error")
		let commit = CompletionList(["itemDefaults": ["commitCharacters": [".", "(("]], "items": [["label": "x"], ["label": "y", "commitCharacters": [";"]]]])
		XCTAssertTrue(commit.items[0].commitCharacters == [0x2E] && commit.items[1].commitCharacters == [0x3B])
		XCTAssertTrue(CompletionList(["items": []]).items.isEmpty && CompletionList([["label": "x"]]).items.count == 1)
	}

	func testFilterIsFuzzyThenSortText() {
		let list = CompletionList(["items": [
			["label": "Sprintf", "sortText": "1"], ["label": "Println", "sortText": "3"],
			["label": "Printf", "sortText": "2"], ["label": "Errorf", "sortText": "0"],
		]])
		XCTAssertEqual(list.filtered(by: ""), [3, 0, 2, 1])
		XCTAssertEqual(list.filtered(by: "prf").map { list.items[$0].label }, ["Printf", "Sprintf"])
		XCTAssertEqual(list.filtered(by: "PRINTL").map { list.items[$0].label }, ["Println"])
	}

	func testOffsetsFollowTypingAtTheCaret() {
		// Requested at 10 ("fmt.P|"), then "ri" typed (caret 12) or "P" deleted (caret 9).
		XCTAssertEqual(completionOffset(9, oldCaret: 10, caret: 12, isEnd: false), 9)
		XCTAssertEqual(completionOffset(10, oldCaret: 10, caret: 12, isEnd: true), 12)
		XCTAssertEqual(completionOffset(10, oldCaret: 10, caret: 12, isEnd: false), 10)
		XCTAssertEqual(completionOffset(15, oldCaret: 10, caret: 12, isEnd: true), 17)
		XCTAssertEqual(completionOffset(9, oldCaret: 10, caret: 8, isEnd: false), 8)
		XCTAssertEqual(completionOffset(0, oldCaret: 10, caret: 8, isEnd: true), 0)
	}
}
