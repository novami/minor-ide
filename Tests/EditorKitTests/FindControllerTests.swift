import AppKit
import Testing
import TextEngine
@testable import EditorKit

@MainActor
struct FindControllerTests {
	func controller(_ text: String, _ query: String) async -> FindController {
		let f = FindController(editor: EditorView(text: text))
		f.showsHighlights = true
		f.query = FindQuery(text: query)
		await f.waitForResults()
		return f
	}

	@Test func incrementalFindSelectsFromOriginAndWraps() async {
		let f = FindController(editor: EditorView(text: "ab ab ab"))
		f.showsHighlights = true
		f.editor.moveCaret(to: 4)
		f.origin = 4
		f.query = FindQuery(text: "ab")
		await f.waitForResults()
		#expect(f.editor.selections.primary.range == 6..<8)
		#expect(f.editor.findMatches.count == 3)
		await f.findNext()
		#expect(f.editor.selections.primary.range == 0..<2)
		#expect(f.currentIndex == 0)
		await f.findNext(forward: false)
		#expect(f.editor.selections.primary.range == 6..<8)
	}

	@Test func replaceAndFindThenReplaceAllIsOneUndo() async {
		let f = await controller("Foo foo FOO", "foo")
		f.replacement = "bar"
		f.preserveCase = true
		await f.findNext()
		#expect(f.editor.selections.primary.range == 0..<3)
		await f.replaceAndFind()
		#expect(f.editor.rope.string == "Bar foo FOO")
		#expect(f.editor.selections.primary.range == 4..<7)
		#expect(await f.replaceAll() == 2)
		#expect(f.editor.rope.string == "Bar bar BAR")
		#expect(f.matches.isEmpty)
		f.editor.undo(nil)
		#expect(f.editor.rope.string == "Bar foo FOO")
	}

	@Test func highlightsFollowTypingAndHideWithBar() async {
		let f = await controller("xx yy xx", "xx")
		f.editor.moveCaret(to: 0)
		f.editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
		#expect(f.editor.findMatches == [1..<3, 7..<9])
		f.showsHighlights = false
		#expect(f.editor.findMatches.isEmpty)
	}
}
