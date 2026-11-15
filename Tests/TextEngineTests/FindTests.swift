import Testing
@testable import TextEngine

struct FindTests {
	let rope = Rope("Řádek jedna\nřádek dva, ŘÁDEK tři\nřádkový")

	@Test func plainIgnoresCaseByDefault() throws {
		#expect(try rope.matches(of: FindQuery(text: "řádek")).count == 3)
		#expect(try rope.matches(of: FindQuery(text: "řádek", caseSensitive: true)) == [14..<21])
	}

	@Test func wholeWordSkipsLongerWords() throws {
		#expect(try rope.matches(of: FindQuery(text: "řád")).count == 4)
		#expect(try rope.matches(of: FindQuery(text: "řád", wholeWord: true)).isEmpty)
		#expect(try rope.matches(of: FindQuery(text: "dva", wholeWord: true)).count == 1)
	}

	@Test func regexAnchorsAtLinesAndReportsErrors() throws {
		let q = FindQuery(text: "^ř\\w+", regex: true)
		#expect(try rope.matches(of: q).map { rope.string(in: $0) } == ["Řádek", "řádek", "řádkový"])
		#expect(throws: FindError.invalidPattern) { try rope.matches(of: FindQuery(text: "(", regex: true)) }
		// Empty matches are skipped instead of looping.
		#expect(try rope.matches(of: FindQuery(text: "x*", regex: true)).isEmpty)
	}

	@Test func replacementsExpandGroupsAndEscapes() throws {
		let r = Rope("a=1\nb=2")
		let q = FindQuery(text: "(\\w)=(\\d)", regex: true)
		let edits = try r.replacements(of: q, with: "$2:$1\\t", preserveCase: false)
		#expect(edits.map(\.1) == ["1:a\t", "2:b\t"])
		#expect(try r.replacement(for: 4..<7, query: q, template: "$2", preserveCase: false) == "2")
		// A plain query takes the template literally.
		#expect(try r.replacements(of: FindQuery(text: "a"), with: "$1", preserveCase: false).map(\.1) == ["$1"])
	}

	@Test func preserveCaseFollowsMatch() {
		#expect(FindQuery.applyingCase(of: "ŘÁDEK", to: "line") == "LINE")
		#expect(FindQuery.applyingCase(of: "Řádek", to: "line") == "Line")
		#expect(FindQuery.applyingCase(of: "řádek", to: "Line") == "line")
		#expect(FindQuery.applyingCase(of: "řÁdek", to: "Line") == "Line")
	}

	@Test func untouchedRangesFollowEdits() {
		let cs = ChangeSet([(2..<2, "xx"), (10..<12, "")])
		#expect(cs.mapUntouched([0..<2, 2..<4, 3..<5, 11..<13, 20..<22]) == [0..<2, 4..<6, 5..<7, 20..<22])
	}
}
