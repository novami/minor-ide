import AppKit
import Testing
@testable import EditorKit

@MainActor
struct EditorFontTests {
	@Test func settingTheFontRelaysOutOpenEditors() {
		let e = EditorView(text: "čeština\nb")
		let saved = EditorView.editorFont
		defer { EditorView.editorFont = saved }
		let small = e.point(of: 3, line: 0)
		EditorView.editorFont = EditorView.font(family: "Menlo", size: 26)
		#expect(e.font.pointSize == 26 && e.font.familyName == "Menlo")
		#expect(e.lineHeight > 26 && e.point(of: 3, line: 0).x > small.x)
	}

	@Test func automaticFontIsMenloWithoutRetina() {
		let f = EditorView.font(family: "No Such Font", size: nil, nonRetina: false)
		#expect(f.pointSize == EditorView.defaultFontSize && f.isFixedPitch && f.familyName != "Menlo")
		let low = EditorView.font(family: nil, size: nil, nonRetina: true)
		#expect(low.familyName == "Menlo" && low.pointSize == EditorView.defaultFontSize)
		#expect(EditorView.font(family: "Monaco", size: 12, nonRetina: true).familyName == "Monaco")
	}
}
