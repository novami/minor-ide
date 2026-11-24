import AppKit
import XCTest
@testable import MinorIDE

@MainActor
final class TextDragTests: XCTestCase {
	let e = EditorView(text: "jedna dva tři\n")

	func at(_ column: Int) -> NSPoint {
		let width = ("0" as NSString).size(withAttributes: [.font: e.font]).width
		return NSPoint(x: e.textInset + (CGFloat(column) + 0.4) * width, y: 0.5 * e.lineHeight)
	}

	var text: String { e.rope.string(in: 0..<e.rope.byteCount) }

	func testOnlyAPlainClickInsideTheSelectionCanDrag() {
		e.setSelections(SelectionSet([Selection(anchor: 6, head: 9)])) // "dva"
		XCTAssertEqual(e.textDragCandidate(at: at(7), clicks: 1, modifiers: [])?.range, 6..<9)
		XCTAssertNil(e.textDragCandidate(at: at(7), clicks: 2, modifiers: []))
		XCTAssertNil(e.textDragCandidate(at: at(7), clicks: 1, modifiers: .shift))
		XCTAssertNil(e.textDragCandidate(at: at(2), clicks: 1, modifiers: []))
	}

	func testMovingIsOneUndoStepAndSelectsTheText() {
		e.dropText("dva", at: 0, moving: 6..<9)
		XCTAssertEqual(text, "dvajedna  tři\n")
		XCTAssertEqual(e.selections.primary.range, 0..<3)
		e.undo(nil)
		XCTAssertEqual(text, "jedna dva tři\n")
		e.dropText("dva", at: 14, moving: 6..<9) // after "tři", moving right
		XCTAssertEqual(text, "jedna  třidva\n")
		XCTAssertEqual(e.rope.string(in: e.selections.primary.range), "dva")
	}

	func testDropInsideTheDraggedTextOnlySelectsIt() {
		e.dropText("dva", at: 7, moving: 6..<9)
		XCTAssertEqual(text, "jedna dva tři\n")
		XCTAssertEqual(e.selections.primary.range, 6..<9)
	}

	func testCopyFromElsewhereInserts() {
		e.dropText("nula ", at: 0, moving: nil)
		XCTAssertEqual(text, "nula jedna dva tři\n")
		XCTAssertEqual(e.selections.primary.range, 0..<5)
	}

	func testLookUpTakesTheSelectionOrTheWordAtTheCaret() {
		e.setSelections(SelectionSet(caret: 7))
		XCTAssertEqual(e.rope.string(in: e.lookUpRange), "dva")
		e.setSelections(SelectionSet([Selection(anchor: 0, head: 9)]))
		XCTAssertEqual(e.rope.string(in: e.lookUpRange), "jedna dva")
	}
}
