import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class AccessibilityTests: XCTestCase {
	func testWrappedLinesAreRows() {
		let e = EditorView(text: "aaaa bbbb cccc\nx")
		var f = FormatSettings()
		f.maxLineLength = 10
		e.format = f
		EditorView.wrapsLines = true
		defer { EditorView.wrapsLines = false }
		XCTAssertEqual(e.accessibilityString(for: e.accessibilityRange(forLine: 0)), "aaaa bbbb ")
		XCTAssertEqual(e.accessibilityString(for: e.accessibilityRange(forLine: 1)), "cccc\n")
		XCTAssertEqual(e.accessibilityString(for: e.accessibilityRange(forLine: 2)), "x")
		XCTAssertEqual(e.accessibilityRange(forLine: 3).location, NSNotFound)
		XCTAssertEqual(e.accessibilityLine(for: 11), 1)
		e.moveCaret(to: 15)
		XCTAssertEqual(e.accessibilityInsertionPointLineNumber(), 2)
	}

	func testAssistiveAppsReplaceTheSelection() {
		let e = EditorView(text: "dobrý den")
		e.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 3))
		e.setAccessibilitySelectedText("večer")
		XCTAssertEqual(e.rope.string(in: 0..<e.rope.byteCount), "dobrý večer")
		XCTAssertEqual(e.accessibilitySelectedTextRange(), NSRange(location: 11, length: 0))
		e.undo(nil)
		XCTAssertEqual(e.rope.string(in: 0..<e.rope.byteCount), "dobrý den")
	}

	func testEditsCarryTheirText() {
		let rope = Rope("kůň")
		let delete = AccessibilityEdit(ChangeSet([(1..<3, "")]), in: rope, kind: .deleting)
		XCTAssertTrue(delete?.deleted == "ů" && delete?.inserted.isEmpty == true)
		let typed = AccessibilityEdit(ChangeSet([(3..<3, "x")]), in: rope, kind: .typing)
		XCTAssertTrue(typed?.inserted == "x" && typed?.typed == true)
		XCTAssertNil(AccessibilityEdit(ChangeSet([(0..<0, "a"), (3..<3, "b")]), in: rope, kind: .typing))
	}

	func testHighContrastThemeReachesSevenToOne() {
		for (theme, bg) in [(Theme.light, (1.0, 1.0, 1.0)), (Theme.dark, (0.12, 0.12, 0.12))] {
			for kind in TokenKind.allCases {
				guard let c = theme.rgba(kind, contrast: 7, against: bg) else { continue }
				XCTAssertTrue(Theme.contrast(Theme.luminance((c.0, c.1, c.2)), Theme.luminance(bg)) >= 7, "\(theme.name) \(kind)")
			}
		}
	}
}
