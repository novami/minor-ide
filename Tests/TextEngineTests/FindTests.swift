import XCTest
@testable import MinorIDE

final class FindTests: XCTestCase {
	let rope = Rope("Řádek jedna\nřádek dva, ŘÁDEK tři\nřádkový")

	func testPlainIgnoresCaseByDefault() throws {
		try XCTAssertEqual(rope.matches(of: FindQuery(text: "řádek")).count, 3)
		try XCTAssertEqual(rope.matches(of: FindQuery(text: "řádek", caseSensitive: true)), [14..<21])
	}

	func testWholeWordSkipsLongerWords() throws {
		try XCTAssertEqual(rope.matches(of: FindQuery(text: "řád")).count, 4)
		try XCTAssertTrue(rope.matches(of: FindQuery(text: "řád", wholeWord: true)).isEmpty)
		try XCTAssertEqual(rope.matches(of: FindQuery(text: "dva", wholeWord: true)).count, 1)
	}

	func testRegexAnchorsAtLinesAndReportsErrors() throws {
		let q = FindQuery(text: "^ř\\w+", regex: true)
		try XCTAssertEqual(rope.matches(of: q).map { rope.string(in: $0) }, ["Řádek", "řádek", "řádkový"])
		XCTAssertThrowsError(try rope.matches(of: FindQuery(text: "(", regex: true)))
		// Empty matches are skipped instead of looping.
		try XCTAssertTrue(rope.matches(of: FindQuery(text: "x*", regex: true)).isEmpty)
	}

	func testReplacementsExpandGroupsAndEscapes() throws {
		let r = Rope("a=1\nb=2")
		let q = FindQuery(text: "(\\w)=(\\d)", regex: true)
		let edits = try r.replacements(of: q, with: "$2:$1\\t", preserveCase: false)
		XCTAssertEqual(edits.map(\.1), ["1:a\t", "2:b\t"])
		try XCTAssertEqual(r.replacement(for: 4..<7, query: q, template: "$2", preserveCase: false), "2")
		// A plain query takes the template literally.
		try XCTAssertEqual(r.replacements(of: FindQuery(text: "a"), with: "$1", preserveCase: false).map(\.1), ["$1"])
	}

	func testReplacingPreviewsOneLine() throws {
		try XCTAssertEqual(Rope.replacing(in: "foo(a) = foo(b)", query: FindQuery(text: "foo\\((\\w)\\)", regex: true), with: "bar[$1]"), "bar[a] = bar[b]")
	}

	func testPreserveCaseFollowsMatch() {
		XCTAssertEqual(FindQuery.applyingCase(of: "ŘÁDEK", to: "line"), "LINE")
		XCTAssertEqual(FindQuery.applyingCase(of: "Řádek", to: "line"), "Line")
		XCTAssertEqual(FindQuery.applyingCase(of: "řádek", to: "Line"), "line")
		XCTAssertEqual(FindQuery.applyingCase(of: "řÁdek", to: "Line"), "Line")
	}

	func testUntouchedRangesFollowEdits() {
		let cs = ChangeSet([(2..<2, "xx"), (10..<12, "")])
		XCTAssertEqual(cs.mapUntouched([0..<2, 2..<4, 3..<5, 11..<13, 20..<22]), [0..<2, 4..<6, 5..<7, 20..<22])
	}
}
