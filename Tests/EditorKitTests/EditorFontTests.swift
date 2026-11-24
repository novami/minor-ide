import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class EditorFontTests: XCTestCase {
	func testSettingTheFontRelaysOutOpenEditors() {
		let e = EditorView(text: "čeština\nb")
		let saved = EditorView.editorFont
		defer { EditorView.editorFont = saved }
		let small = e.point(of: 3, line: 0)
		EditorView.editorFont = EditorView.font(family: "Menlo", size: 26)
		XCTAssertTrue(e.font.pointSize == 26 && e.font.familyName == "Menlo")
		XCTAssertTrue(e.lineHeight > 26 && e.point(of: 3, line: 0).x > small.x)
	}

	func testAutomaticFontIsMenloWithoutRetina() {
		let f = EditorView.font(family: "No Such Font", size: nil, nonRetina: false)
		XCTAssertTrue(f.pointSize == EditorView.defaultFontSize && f.isFixedPitch && f.familyName != "Menlo")
		let low = EditorView.font(family: nil, size: nil, nonRetina: true)
		XCTAssertTrue(low.familyName == "Menlo" && low.pointSize == EditorView.defaultFontSize)
		XCTAssertEqual(EditorView.font(family: "Monaco", size: 12, nonRetina: true).familyName, "Monaco")
	}
}
