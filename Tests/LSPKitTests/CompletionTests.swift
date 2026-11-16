import MinorCore
import Testing
import TextEngine
@testable import LSPKit

struct CompletionTests {
	@Test func listWithDefaultsAndResolve() {
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
		#expect(list.isIncomplete && list.items.count == 3)
		let a = list.items[0], b = list.items[1]
		#expect(a.isSnippet && a.snippet.text == "Println()" && a.documentation == "prints")
		#expect(a.range == LSPRange(start: Position(line: 0, character: 4), end: Position(line: 0, character: 5)))
		#expect(!b.isSnippet && b.additionalTextEdits.count == 1 && list.items[2].deprecated)
		var c = list.items[2]
		c.merge(resolved: ["label": "Errorf", "detail": "func(format string) error"])
		#expect(c.resolved && c.detail == "func(format string) error")
		#expect(CompletionList(["items": []]).items.isEmpty && CompletionList([["label": "x"]]).items.count == 1)
	}

	@Test func filterIsFuzzyThenSortText() {
		let list = CompletionList(["items": [
			["label": "Sprintf", "sortText": "1"], ["label": "Println", "sortText": "3"],
			["label": "Printf", "sortText": "2"], ["label": "Errorf", "sortText": "0"],
		]])
		#expect(list.filtered(by: "") == [3, 0, 2, 1])
		#expect(list.filtered(by: "prf").map { list.items[$0].label } == ["Printf", "Sprintf"])
		#expect(list.filtered(by: "PRINTL").map { list.items[$0].label } == ["Println"])
	}

	@Test func offsetsFollowTypingAtTheCaret() {
		// Requested at 10 ("fmt.P|"), then "ri" typed (caret 12) or "P" deleted (caret 9).
		#expect(completionOffset(9, oldCaret: 10, caret: 12, isEnd: false) == 9)
		#expect(completionOffset(10, oldCaret: 10, caret: 12, isEnd: true) == 12)
		#expect(completionOffset(10, oldCaret: 10, caret: 12, isEnd: false) == 10)
		#expect(completionOffset(15, oldCaret: 10, caret: 12, isEnd: true) == 17)
		#expect(completionOffset(9, oldCaret: 10, caret: 8, isEnd: false) == 8)
		#expect(completionOffset(0, oldCaret: 10, caret: 8, isEnd: true) == 0)
	}
}
