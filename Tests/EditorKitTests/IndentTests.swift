import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class IndentTests: XCTestCase {
	func editor(_ text: String, style: IndentStyle, size: Int = 4, caretAtEnd: Bool = true) -> EditorView {
		let e = EditorView(text: text)
		var f = FormatSettings()
		f.indentStyle = style
		f.indentSize = size
		e.format = f
		if caretAtEnd { e.moveCaret(to: e.rope.byteCount) }
		return e
	}

	func testTabInsertsSpacesToNextStop() {
		let e = editor("ab", style: .space, size: 4)
		e.doCommand(by: #selector(NSResponder.insertTab(_:)))
		XCTAssertEqual(e.rope.string, "ab  ")
		e.doCommand(by: #selector(NSResponder.insertTab(_:)))
		XCTAssertEqual(e.rope.string, "ab      ")
	}

	func testTabInsertsTabCharacter() {
		let e = editor("ab", style: .tab)
		e.doCommand(by: #selector(NSResponder.insertTab(_:)))
		XCTAssertEqual(e.rope.string, "ab\t")
	}

	func testEnterKeepsIndentation() {
		let e = editor("func a() {\n\t\tx := 1", style: .tab)
		e.doCommand(by: #selector(NSResponder.insertNewline(_:)))
		XCTAssertEqual(e.rope.string, "func a() {\n\t\tx := 1\n\t\t")
	}

	func testBacktabRemovesOneLevel() {
		let e = editor("        return;", style: .space, size: 4)
		e.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
		XCTAssertEqual(e.rope.string, "    return;")
		let t = editor("\t\treturn;", style: .tab)
		t.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
		XCTAssertEqual(t.rope.string, "\treturn;")
	}

	func testVisualColumnCountsTabStops() {
		let e = editor("\tab\tc", style: .tab)
		XCTAssertEqual(e.visualColumn(e.rope.byteCount), 9) // tab→4, "ab"→6, tab→8, "c"→9
	}
}
