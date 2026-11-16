import Testing
@testable import TextEngine

struct SnippetTests {
	func ranges(_ s: Snippet) -> [[String]] {
		let b = Array(s.text.utf8)
		return s.stops.map { $0.map { String(decoding: b[$0], as: UTF8.self) } }
	}

	@Test func stopsInOrderWithFinalLast() {
		let s = Snippet(parsing: "Printf(${1:format}, ${2:a ...any})$0")
		#expect(s.text == "Printf(format, a ...any)")
		#expect(ranges(s) == [["format"], ["a ...any"], [""]])
		#expect(s.stops.last == [24..<24])
	}

	@Test func nestedChoiceVariablesEscapesAndMirrors() {
		let s = Snippet(parsing: "for ${1:i} := ${2:0}; $1 < ${3|n,len(x)|}; ${1}++ {\n\t$0\n} \\$x ${TM_FILENAME:f} $ ${4:a${5:b}}")
		#expect(s.text == "for i := 0;  < n; ++ {\n\t\n} $x f $ ab")
		#expect(ranges(s) == [["i", "", ""], ["0"], ["n"], ["ab"], ["b"], [""]])
	}

	@Test func noStopsEndsAtTheEndAndIndentShiftsStops() {
		#expect(Snippet(parsing: "plain").stops == [[5..<5]])
		let s = Snippet(parsing: "if ${1:x} {\n\t$0\n}").indented("\t\t")
		#expect(s.text == "if x {\n\t\t\t\n\t\t}")
		#expect(ranges(s) == [["x"], [""]])
		#expect(s.stops[1] == [10..<10])
	}
}
