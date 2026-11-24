import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class FindControllerTests: XCTestCase {
	func controller(_ text: String, _ query: String) async -> FindController {
		let f = FindController(editor: EditorView(text: text))
		f.showsHighlights = true
		f.query = FindQuery(text: query)
		await f.waitForResults()
		return f
	}

	func testIncrementalFindSelectsFromOriginAndWraps() async {
		let f = FindController(editor: EditorView(text: "ab ab ab"))
		f.showsHighlights = true
		f.editor.moveCaret(to: 4)
		f.origin = 4
		f.query = FindQuery(text: "ab")
		await f.waitForResults()
		XCTAssertEqual(f.editor.selections.primary.range, 6..<8)
		XCTAssertEqual(f.editor.findMatches.count, 3)
		await f.findNext()
		XCTAssertEqual(f.editor.selections.primary.range, 0..<2)
		XCTAssertEqual(f.currentIndex, 0)
		await f.findNext(forward: false)
		XCTAssertEqual(f.editor.selections.primary.range, 6..<8)
	}

	func testReplaceAndFindThenReplaceAllIsOneUndo() async {
		let f = await controller("Foo foo FOO", "foo")
		f.replacement = "bar"
		f.preserveCase = true
		await f.findNext()
		XCTAssertEqual(f.editor.selections.primary.range, 0..<3)
		await f.replaceAndFind()
		XCTAssertEqual(f.editor.rope.string, "Bar foo FOO")
		XCTAssertEqual(f.editor.selections.primary.range, 4..<7)
		let replaced = await f.replaceAll()
		XCTAssertEqual(replaced, 2)
		XCTAssertEqual(f.editor.rope.string, "Bar bar BAR")
		XCTAssertTrue(f.matches.isEmpty)
		f.editor.undo(nil)
		XCTAssertEqual(f.editor.rope.string, "Bar foo FOO")
	}

	func testHighlightsFollowTypingAndHideWithBar() async {
		let f = await controller("xx yy xx", "xx")
		f.editor.moveCaret(to: 0)
		f.editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
		XCTAssertEqual(f.editor.findMatches, [1..<3, 7..<9])
		f.showsHighlights = false
		XCTAssertTrue(f.editor.findMatches.isEmpty)
	}
}
