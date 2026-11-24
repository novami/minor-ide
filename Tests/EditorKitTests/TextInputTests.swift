import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class TextInputTests: XCTestCase {
	let none = NSRange(location: NSNotFound, length: 0)

	/// Czech layout: most letters are direct keys, the rest come through dead keys (ˇ, ´, °).
	func testCzechKeyboard() {
		let e = EditorView(text: "")
		for c in "čšžýáíéůú" { e.insertText(String(c), replacementRange: none) }
		for (dead, letter) in [("ˇ", "ď"), ("´", "Ó"), ("°", "Ů")] {
			e.setMarkedText(dead, selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
			XCTAssertTrue(e.hasMarkedText() && e.rope.string.utf8.count == e.caret)
			e.insertText(letter, replacementRange: none)
		}
		XCTAssertTrue(e.rope.string == "čšžýáíéůúďÓŮ" && !e.hasMarkedText())
		e.undo(nil)
		XCTAssertEqual(e.rope.string, "")
	}

	func testKeyEventsReachTheDocument() throws {
		let e = EditorView(text: "")
		for c in ["č", "ů", "😀"] {
			let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
				windowNumber: 0, context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0))
			e.interpretKeyEvents([event])
		}
		XCTAssertEqual(e.rope.string, "čů😀")
	}

	/// Press-and-hold: the accent menu replaces the letter already typed.
	func testReplacementRangeReplacesDocumentText() {
		let e = EditorView(text: "x😀")
		e.moveCaret(to: e.rope.byteCount)
		e.insertText("e", replacementRange: none)
		e.insertText("é", replacementRange: NSRange(location: 3, length: 1))
		XCTAssertTrue(e.rope.string == "x😀é" && e.caret == e.rope.byteCount)
		var actual = NSRange()
		XCTAssertEqual(e.attributedSubstring(forProposedRange: NSRange(location: 1, length: 9), actualRange: &actual)?.string, "😀é")
		XCTAssertEqual(actual, NSRange(location: 1, length: 3))
		XCTAssertEqual(e.selectedRange(), NSRange(location: 4, length: 0))
	}

	func testSystemBindings() {
		let e = EditorView(text: "foo_bar->baz(1)\nqux")
		e.moveCaret(to: 0)
		e.doCommand(by: #selector(NSResponder.moveWordRight(_:)))
		XCTAssertEqual(e.caret, 7)
		e.doCommand(by: #selector(NSResponder.moveWordRight(_:)))
		XCTAssertEqual(e.caret, 9)
		e.doCommand(by: #selector(NSResponder.deleteWordBackward(_:)))
		XCTAssertEqual(e.rope.string, "foo_barbaz(1)\nqux")
		e.doCommand(by: #selector(NSResponder.deleteToEndOfParagraph(_:))) // ⌃K
		XCTAssertEqual(e.rope.string, "foo_bar\nqux")
		e.doCommand(by: #selector(NSResponder.deleteToEndOfParagraph(_:))) // joins the next line
		XCTAssertEqual(e.rope.string, "foo_barqux")
		e.doCommand(by: #selector(NSResponder.moveToBeginningOfParagraph(_:))) // ⌃A
		e.doCommand(by: #selector(NSResponder.yank(_:))) // ⌃Y
		XCTAssertEqual(e.rope.string, "\nfoo_barqux")
		e.doCommand(by: #selector(NSResponder.moveToEndOfParagraph(_:))) // ⌃E
		e.doCommand(by: #selector(NSResponder.transpose(_:))) // ⌃T
		XCTAssertEqual(e.rope.string, "\nfoo_barqxu")
	}
}

@MainActor
final class DictationTests: XCTestCase {
	/// Dictation shows partial text as marked text and commits it with unmarkText.
	func testUnmarkTextCommitsMarkedText() {
		let e = EditorView(text: "ab")
		e.moveCaret(to: 1)
		e.setMarkedText("ahoj", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
		e.setMarkedText("ahoj světe", selectedRange: NSRange(location: 10, length: 0), replacementRange: e.markedRange())
		e.unmarkText()
		XCTAssertEqual(e.rope.string, "aahoj světeb")
	}

	func testInsertingOverMarkedRangeKeepsFollowingText() {
		let e = EditorView(text: "xyz")
		e.moveCaret(to: 0)
		e.setMarkedText("ab", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
		e.insertText("abc", replacementRange: e.markedRange())
		XCTAssertEqual(e.rope.string, "abcxyz")
	}
}
