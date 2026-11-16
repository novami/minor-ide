import AppKit
import Highlight
import MinorCore
import Testing
import TextEngine
@testable import EditorKit

@MainActor
struct AccessibilityTests {
	@Test func wrappedLinesAreRows() {
		let e = EditorView(text: "aaaa bbbb cccc\nx")
		var f = FormatSettings()
		f.maxLineLength = 10
		e.format = f
		EditorView.wrapsLines = true
		defer { EditorView.wrapsLines = false }
		#expect(e.accessibilityString(for: e.accessibilityRange(forLine: 0)) == "aaaa bbbb ")
		#expect(e.accessibilityString(for: e.accessibilityRange(forLine: 1)) == "cccc\n")
		#expect(e.accessibilityString(for: e.accessibilityRange(forLine: 2)) == "x")
		#expect(e.accessibilityRange(forLine: 3).location == NSNotFound)
		#expect(e.accessibilityLine(for: 11) == 1)
		e.moveCaret(to: 15)
		#expect(e.accessibilityInsertionPointLineNumber() == 2)
	}

	@Test func assistiveAppsReplaceTheSelection() {
		let e = EditorView(text: "dobrý den")
		e.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 3))
		e.setAccessibilitySelectedText("večer")
		#expect(e.rope.string(in: 0..<e.rope.byteCount) == "dobrý večer")
		#expect(e.accessibilitySelectedTextRange() == NSRange(location: 11, length: 0))
		e.undo(nil)
		#expect(e.rope.string(in: 0..<e.rope.byteCount) == "dobrý den")
	}

	@Test func editsCarryTheirText() {
		let rope = Rope("kůň")
		let delete = AccessibilityEdit(ChangeSet([(1..<3, "")]), in: rope, kind: .deleting)
		#expect(delete?.deleted == "ů" && delete?.inserted == "")
		let typed = AccessibilityEdit(ChangeSet([(3..<3, "x")]), in: rope, kind: .typing)
		#expect(typed?.inserted == "x" && typed?.typed == true)
		#expect(AccessibilityEdit(ChangeSet([(0..<0, "a"), (3..<3, "b")]), in: rope, kind: .typing) == nil)
	}

	@Test func highContrastThemeReachesSevenToOne() {
		for (theme, bg) in [(Theme.light, (1.0, 1.0, 1.0)), (Theme.dark, (0.12, 0.12, 0.12))] {
			for kind in TokenKind.allCases {
				guard let c = theme.rgba(kind, contrast: 7, against: bg) else { continue }
				#expect(Theme.contrast(Theme.luminance((c.0, c.1, c.2)), Theme.luminance(bg)) >= 7, "\(theme.name) \(kind)")
			}
		}
	}
}
