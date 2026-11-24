import XCTest
@testable import MinorIDE

final class WrapTests: XCTestCase {
	func breaks(_ s: String, _ column: Int, tab: Int = 4) -> [Int] {
		WrapMap.breaks(Array(s.utf8), column: column, tabWidth: tab)
	}

	func testBreaksAfterSpacesOrAtTheColumn() {
		XCTAssertEqual(breaks("aaaa bbbb cccc", 10), [10])
		XCTAssertEqual(breaks("abcdefghijkl", 5), [5, 10])
		XCTAssertEqual(breaks("short", 10), [])
		XCTAssertEqual(breaks("\tx", 4), [1]) // a tab fills the row
		XCTAssertEqual(breaks("abcde\u{301}f", 5), [6]) // the accent stays with its letter
		XCTAssertEqual(breaks("😀😀😀", 2), [4]) // UTF-16 units
		XCTAssertEqual(breaks("aaaa      bb", 4), [10]) // spaces hang past the column
	}

	func testDisplayMapWithWrapsAndFolds() {
		let map = DisplayMap(hidden: [3...4], wrapped: [(1, 2), (4, 1), (5, 1)])
		XCTAssertEqual(map.rowCount(lineCount: 6), 7)
		XCTAssertEqual((0..<7).map { map.position(atRow: $0).line }, [0, 1, 1, 1, 2, 5, 5])
		XCTAssertTrue(map.position(atRow: 2) == (1, 1) && map.position(atRow: 6) == (5, 1))
		XCTAssertEqual((0..<6).map(map.row(of:)), [0, 1, 4, 4, 4, 5])
		XCTAssertTrue(map.rows(ofLine: 1) == 3 && map.rows(ofLine: 4) == 1)
	}

	func testUpdateMatchesFullComputation() {
		var rng = SplitMix64(seed: 7)
		let words = ["a", "bb", "ccc ", " ", "\t", "dddddddd", "\n", "é", "😀"]
		var rope = Rope((0..<200).map { _ in words.randomElement(using: &rng)! }.joined())
		var map = WrapMap(rope: rope, column: 6, tabWidth: 4)
		for _ in 0..<300 {
			let a = Int.random(in: 0...rope.byteCount, using: &rng)
			let start = rope.scalarBoundary(atOrBefore: a)
			let end = rope.scalarBoundary(atOrBefore: min(rope.byteCount, start + Int.random(in: 0...12, using: &rng)))
			let text = (0..<Int.random(in: 0...4, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined()
			let first = rope.line(containing: start), oldLast = rope.line(containing: end), oldCount = rope.lineCount
			ChangeSet([(start..<end, text)]).apply(to: &rope)
			map.update(rope: rope, first: first, oldLast: oldLast, newLast: oldLast + rope.lineCount - oldCount)
			XCTAssertEqual(map, WrapMap(rope: rope, column: 6, tabWidth: 4))
		}
	}

	func testWidestLineInColumns() {
		let rope = Rope("ab\n\tx\nčeština😀\n" + String(repeating: "y", count: 70_000) + "\nz")
		XCTAssertEqual(rope.maxColumns(tabWidth: 4), 70_000) // spans chunks
		XCTAssertEqual(rope.maxColumns(tabWidth: 4, lines: 0...2), 8)
		XCTAssertEqual(rope.maxColumns(tabWidth: 8, lines: 1...1), 9)
	}
}
