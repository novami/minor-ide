import XCTest
@testable import MinorIDE

final class LineChangesTests: XCTestCase {
	private func changes(_ base: String, _ current: String) -> [LineChange] {
		LineChanges.compute(base: LineChanges.lines(base), current: LineChanges.lines(current))
	}

	func testAddedModifiedDeleted() {
		let base = "a\nb\nc\nd\ne\n"
		XCTAssertTrue(changes(base, base).isEmpty)
		XCTAssertEqual(changes(base, "a\nb\nX\nc\nd\ne\n"), [LineChange(kind: .added, lines: 2..<3, old: 2..<2)])
		XCTAssertEqual(changes(base, "a\nB\nc\nd\ne\n"), [LineChange(kind: .modified, lines: 1..<2, old: 1..<2)])
		XCTAssertEqual(changes(base, "a\nd\ne\n"), [LineChange(kind: .deleted, lines: 1..<1, old: 1..<3)])
		XCTAssertTrue(changes(base, "a\r\nb\r\nc\r\nd\r\ne\r\n").isEmpty) // line endings alone are no change
		XCTAssertEqual(changes(base, "Z\nb\nc\nd\nE\nF\n"), [
			LineChange(kind: .modified, lines: 0..<1, old: 0..<1),
			LineChange(kind: .modified, lines: 4..<6, old: 4..<5),
		])
	}
}
