import Testing
@testable import TextEngine

struct LineChangesTests {
	private func changes(_ base: String, _ current: String) -> [LineChange] {
		LineChanges.compute(base: LineChanges.lines(base), current: LineChanges.lines(current))
	}

	@Test func addedModifiedDeleted() {
		let base = "a\nb\nc\nd\ne\n"
		#expect(changes(base, base).isEmpty)
		#expect(changes(base, "a\nb\nX\nc\nd\ne\n") == [LineChange(kind: .added, lines: 2..<3, old: 2..<2)])
		#expect(changes(base, "a\nB\nc\nd\ne\n") == [LineChange(kind: .modified, lines: 1..<2, old: 1..<2)])
		#expect(changes(base, "a\nd\ne\n") == [LineChange(kind: .deleted, lines: 1..<1, old: 1..<3)])
		#expect(changes(base, "a\r\nb\r\nc\r\nd\r\ne\r\n").isEmpty) // line endings alone are no change
		#expect(changes(base, "Z\nb\nc\nd\nE\nF\n") == [
			LineChange(kind: .modified, lines: 0..<1, old: 0..<1),
			LineChange(kind: .modified, lines: 4..<6, old: 4..<5),
		])
	}
}
