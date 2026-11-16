import AppKit
import Testing
import TextEngine
@testable import EditorKit

@MainActor
struct TextDragTests {
	let e = EditorView(text: "jedna dva tři\n")

	func at(_ column: Int) -> NSPoint {
		let width = ("0" as NSString).size(withAttributes: [.font: e.font]).width
		return NSPoint(x: e.textInset + (CGFloat(column) + 0.4) * width, y: 0.5 * e.lineHeight)
	}

	var text: String { e.rope.string(in: 0..<e.rope.byteCount) }

	@Test func onlyAPlainClickInsideTheSelectionCanDrag() {
		e.setSelections(SelectionSet([Selection(anchor: 6, head: 9)])) // "dva"
		#expect(e.textDragCandidate(at: at(7), clicks: 1, modifiers: [])?.range == 6..<9)
		#expect(e.textDragCandidate(at: at(7), clicks: 2, modifiers: []) == nil)
		#expect(e.textDragCandidate(at: at(7), clicks: 1, modifiers: .shift) == nil)
		#expect(e.textDragCandidate(at: at(2), clicks: 1, modifiers: []) == nil)
	}

	@Test func movingIsOneUndoStepAndSelectsTheText() {
		e.dropText("dva", at: 0, moving: 6..<9)
		#expect(text == "dvajedna  tři\n")
		#expect(e.selections.primary.range == 0..<3)
		e.undo(nil)
		#expect(text == "jedna dva tři\n")
		e.dropText("dva", at: 14, moving: 6..<9) // after "tři", moving right
		#expect(text == "jedna  třidva\n")
		#expect(e.rope.string(in: e.selections.primary.range) == "dva")
	}

	@Test func dropInsideTheDraggedTextOnlySelectsIt() {
		e.dropText("dva", at: 7, moving: 6..<9)
		#expect(text == "jedna dva tři\n")
		#expect(e.selections.primary.range == 6..<9)
	}

	@Test func copyFromElsewhereInserts() {
		e.dropText("nula ", at: 0, moving: nil)
		#expect(text == "nula jedna dva tři\n")
		#expect(e.selections.primary.range == 0..<5)
	}

	@Test func lookUpTakesTheSelectionOrTheWordAtTheCaret() {
		e.setSelections(SelectionSet(caret: 7))
		#expect(e.rope.string(in: e.lookUpRange) == "dva")
		e.setSelections(SelectionSet([Selection(anchor: 0, head: 9)]))
		#expect(e.rope.string(in: e.lookUpRange) == "jedna dva")
	}
}
