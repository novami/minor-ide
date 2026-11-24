import XCTest
@testable import MinorIDE

final class SnippetTests: XCTestCase {
	func ranges(_ s: Snippet) -> [[String]] {
		let b = Array(s.text.utf8)
		return s.stops.map { $0.map { String(decoding: b[$0], as: UTF8.self) } }
	}

	func testStopsInOrderWithFinalLast() {
		let s = Snippet(parsing: "Printf(${1:format}, ${2:a ...any})$0")
		XCTAssertEqual(s.text, "Printf(format, a ...any)")
		XCTAssertEqual(ranges(s), [["format"], ["a ...any"], [""]])
		XCTAssertEqual(s.stops.last, [24..<24])
	}

	func testNestedChoiceVariablesEscapesAndMirrors() {
		let s = Snippet(parsing: "for ${1:i} := ${2:0}; $1 < ${3|n,len(x)|}; ${1}++ {\n\t$0\n} \\$x ${TM_FILENAME:f} $ ${4:a${5:b}}")
		XCTAssertEqual(s.text, "for i := 0;  < n; ++ {\n\t\n} $x f $ ab")
		XCTAssertEqual(ranges(s), [["i", "", ""], ["0"], ["n"], ["ab"], ["b"], [""]])
	}

	func testNoStopsEndsAtTheEndAndIndentShiftsStops() {
		XCTAssertEqual(Snippet(parsing: "plain").stops, [[5..<5]])
		let s = Snippet(parsing: "if ${1:x} {\n\t$0\n}").indented("\t\t")
		XCTAssertEqual(s.text, "if x {\n\t\t\t\n\t\t}")
		XCTAssertEqual(ranges(s), [["x"], [""]])
		XCTAssertEqual(s.stops[1], [10..<10])
	}
}
