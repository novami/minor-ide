import AppKit
import MinorCore
import Testing
@testable import EditorKit

@MainActor
struct IndentTests {
	func editor(_ text: String, style: IndentStyle, size: Int = 4, caretAtEnd: Bool = true) -> EditorView {
		let e = EditorView(text: text)
		var f = FormatSettings()
		f.indentStyle = style
		f.indentSize = size
		e.format = f
		if caretAtEnd { e.moveCaret(to: e.rope.byteCount) }
		return e
	}

	@Test func tabInsertsSpacesToNextStop() {
		let e = editor("ab", style: .space, size: 4)
		e.doCommand(by: #selector(NSResponder.insertTab(_:)))
		#expect(e.rope.string == "ab  ")
		e.doCommand(by: #selector(NSResponder.insertTab(_:)))
		#expect(e.rope.string == "ab      ")
	}

	@Test func tabInsertsTabCharacter() {
		let e = editor("ab", style: .tab)
		e.doCommand(by: #selector(NSResponder.insertTab(_:)))
		#expect(e.rope.string == "ab\t")
	}

	@Test func enterKeepsIndentation() {
		let e = editor("func a() {\n\t\tx := 1", style: .tab)
		e.doCommand(by: #selector(NSResponder.insertNewline(_:)))
		#expect(e.rope.string == "func a() {\n\t\tx := 1\n\t\t")
	}

	@Test func backtabRemovesOneLevel() {
		let e = editor("        return;", style: .space, size: 4)
		e.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
		#expect(e.rope.string == "    return;")
		let t = editor("\t\treturn;", style: .tab)
		t.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
		#expect(t.rope.string == "\treturn;")
	}

	@Test func visualColumnCountsTabStops() {
		let e = editor("\tab\tc", style: .tab)
		#expect(e.visualColumn(e.rope.byteCount) == 9) // tab→4, "ab"→6, tab→8, "c"→9
	}
}
