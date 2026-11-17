import AppKit
import Testing
import TextEngine
@testable import EditorKit

@MainActor
struct DiagnosticsTests {
	@Test func problemsFollowEditsAndAreReplaced() {
		let a = EditorView(text: "let x = y\nz\n")
		a.document.setDiagnostics([
			EditorDiagnostic(range: 10..<11, severity: .warning, message: "z"),
			EditorDiagnostic(range: 8..<9, severity: .error, message: "y"),
		])
		#expect(a.document.diagnostics.map(\.message) == ["y", "z"]) // text order
		a.replace([(0..<0, "// c\n")])
		#expect(a.document.diagnostics.map(\.range) == [13..<14, 15..<16])
		#expect(a.worstDiagnostics(lines: 0...2) == [1: a.document.diagnostics[0], 2: a.document.diagnostics[1]])
		let anchors = a.document.anchors.count
		a.document.setDiagnostics([EditorDiagnostic(range: 0..<2, severity: .hint, message: "h")])
		#expect(a.document.diagnostics.map(\.message) == ["h"])
		#expect(a.document.anchors.count == anchors - 2) // old anchors released
	}

	/// The resting mouse finds a problem off words too (an operator).
	@Test func problemUnderThePointer() {
		let a = EditorView(text: "a := b +\n")
		a.document.setDiagnostics([EditorDiagnostic(range: 7..<8, severity: .error, message: "expected operand")])
		let r = a.rangeRects(7..<8, lines: 0...0)[0]
		#expect(a.diagnosticRange(at: NSPoint(x: r.midX, y: r.midY)) == 7..<8)
		#expect(a.diagnosticRange(at: NSPoint(x: a.rangeRects(0..<1, lines: 0...0)[0].midX, y: r.midY)) == nil)
	}

	/// F2 / ⇧F2: from the caret to the next / previous problem, around the end; hints are
	/// skipped while there are other problems.
	@Test func nextAndPreviousProblemWrapAround() {
		let a = EditorView(text: "aaa\nbbb\nccc\n")
		a.document.setDiagnostics([
			EditorDiagnostic(range: 4..<7, severity: .error, message: "b"),
			EditorDiagnostic(range: 8..<9, severity: .warning, message: "c"),
			EditorDiagnostic(range: 1..<2, severity: .hint, message: "a"),
		])
		a.setSelections(SelectionSet(caret: 0))
		#expect(a.goToDiagnostic(forward: true)?.message == "b" && a.caret == 4)
		#expect(a.goToDiagnostic(forward: true)?.message == "c" && a.caret == 8)
		#expect(a.goToDiagnostic(forward: true)?.message == "b") // around the end
		#expect(a.goToDiagnostic(forward: false)?.message == "c") // around the start
		a.document.setDiagnostics([])
		#expect(a.goToDiagnostic(forward: true) == nil)
	}
}
