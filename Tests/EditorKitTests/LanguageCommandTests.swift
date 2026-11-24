import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class LanguageCommandTests: XCTestCase {
	func editor(_ text: String, _ language: SyntaxLanguage, caret: Int? = nil) -> EditorView {
		let e = EditorView(text: text)
		var f = FormatSettings()
		f.indentStyle = .tab
		e.format = f
		e.language = language
		e.moveCaret(to: caret ?? text.utf8.count)
		return e
	}

	func type(_ e: EditorView, _ text: String) {
		for c in text { e.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) }
	}

	func testLineCommentsToggleAtCommonIndent() {
		let e = editor("func a() {\n\tx()\n\n\t\ty()\n}", .go)
		e.setSelections(SelectionSet([Selection(anchor: 11, head: e.rope.offset(ofLine: 3) + 2)]))
		e.toggleComment(nil)
		XCTAssertEqual(e.rope.string, "func a() {\n\t// x()\n\n\t// \ty()\n}")
		e.toggleComment(nil)
		XCTAssertEqual(e.rope.string, "func a() {\n\tx()\n\n\t\ty()\n}")
	}

	func testBlockCommentsInLatteAndHTMLPartsOfPHP() {
		let latte = editor("<p>{$x}</p>", .latte, caret: 0)
		latte.toggleComment(nil)
		XCTAssertEqual(latte.rope.string, "{* <p>{$x}</p> *}")
		latte.toggleComment(nil)
		XCTAssertEqual(latte.rope.string, "<p>{$x}</p>")
		let php = editor("<?php\n$a = 1;\n?>\n<b>x</b>", .php, caret: 0)
		php.moveCaret(to: php.rope.offset(ofLine: 3))
		php.toggleComment(nil)
		XCTAssertEqual(php.rope.string, "<?php\n$a = 1;\n?>\n<!-- <b>x</b> -->")
		php.moveCaret(to: php.rope.offset(ofLine: 1))
		php.toggleComment(nil)
		XCTAssertEqual(php.rope.string, "<?php\n// $a = 1;\n?>\n<!-- <b>x</b> -->")
	}

	func testPairsWrapAndTypeOver() {
		let e = editor("f", .go)
		type(e, "(")
		XCTAssertTrue(e.rope.string == "f()" && e.caret == 2)
		type(e, "\"")
		XCTAssertTrue(e.rope.string == "f(\"\")" && e.caret == 3)
		type(e, "a\"")
		XCTAssertTrue(e.rope.string == "f(\"a\")" && e.caret == 5)
		type(e, ")")
		XCTAssertTrue(e.rope.string == "f(\"a\")" && e.caret == 6)
		// Wrapping keeps the inner text selected.
		e.setSelections(SelectionSet([Selection(anchor: 3, head: 4)]))
		type(e, "[")
		XCTAssertTrue(e.rope.string == "f(\"[a]\")" && e.selections.primary.range == 4..<5)
	}

	func testNoPairsInsideStringsOrAfterWords() {
		let e = editor("s := \"x  y\"", .go, caret: 8)
		type(e, "(")
		XCTAssertEqual(e.rope.string, "s := \"x ( y\"")
		let words = editor("don", .php)
		type(words, "'")
		XCTAssertEqual(words.rope.string, "don'")
	}

	func testBackspaceDeletesEmptyPair() {
		let e = editor("x", .go)
		type(e, "[")
		e.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
		XCTAssertEqual(e.rope.string, "x")
	}

	func testEnterIndentsAfterBracketAndSplitsPair() {
		let e = editor("func a() {", .go)
		type(e, "}")
		XCTAssertEqual(e.rope.string, "func a() {}")
		e.moveCaret(to: 10)
		e.doCommand(by: #selector(NSResponder.insertNewline(_:)))
		XCTAssertEqual(e.rope.string, "func a() {\n\t\n}")
		XCTAssertEqual(e.caret, 12)
		let neon = editor("services:", .neon)
		neon.doCommand(by: #selector(NSResponder.insertNewline(_:)))
		XCTAssertEqual(neon.rope.string, "services:\n\t")
	}

	func testClosingBracketOutdentsEmptyLine() {
		let e = editor("if x {\n\t\t", .go)
		type(e, "}")
		XCTAssertEqual(e.rope.string, "if x {\n\t}")
	}
}
