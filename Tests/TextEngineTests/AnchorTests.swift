import XCTest
@testable import MinorIDE

final class AnchorTests: XCTestCase {
	func testFollowsEditsAndUndo() {
		var rope = Rope("ab\ncd\nef")
		var anchors = AnchorSet()
		let line3 = anchors.add(at: 6) // start of "ef"
		let insertPoint = anchors.add(at: 3, bias: .after)
		let deleted = anchors.add(at: 4)

		let cs = ChangeSet([(0..<0, "//\n"), (3..<3, "X"), (3..<5, "")])
		let inverse = cs.inverted(against: rope)
		cs.apply(to: &rope)
		anchors.apply(cs)
		XCTAssertEqual(rope.string, "//\nab\nX\nef")
		XCTAssertEqual(anchors.offset(of: line3), 8)
		XCTAssertEqual(anchors.offset(of: insertPoint), 7) // after "X"
		XCTAssertEqual(anchors.offset(of: deleted), 7) // collapsed to the deletion point
		XCTAssertEqual(anchors.anchors(in: 7...7).map(\.id), [insertPoint, deleted])

		inverse.apply(to: &rope)
		anchors.apply(inverse)
		XCTAssertEqual(rope.string, "ab\ncd\nef")
		XCTAssertEqual(anchors.offset(of: line3), 6)
		anchors.remove(line3)
		XCTAssertTrue(anchors.offset(of: line3) == nil && anchors.count == 2)
	}

	/// The binary search in `ChangeSet.map` against a plain linear scan.
	func testMapMatchesLinearReference() {
		var rng = SplitMix64(seed: 11)
		for _ in 0..<500 {
			let length = Int(rng.next() % 60)
			let edits = (0..<Int(rng.next() % 6)).map { _ -> (Range<Int>, String) in
				let a = Int(rng.next() % UInt64(length + 1)), b = Int(rng.next() % UInt64(length + 1))
				return (min(a, b)..<max(a, b), String(repeating: "x", count: Int(rng.next() % 3)))
			}
			let cs = ChangeSet(edits)
			for offset in 0...length {
				for bias in [ChangeSet.Bias.before, .after] {
					XCTAssertEqual(cs.map(offset, bias: bias), linearMap(cs, offset, bias))
				}
			}
		}
	}

	private func linearMap(_ cs: ChangeSet, _ offset: Int, _ bias: ChangeSet.Bias) -> Int {
		var delta = 0
		for c in cs.changes {
			if offset < c.range.lowerBound { break }
			if offset > c.range.upperBound || (offset == c.range.upperBound && !c.range.isEmpty) {
				delta += c.text.count - c.range.count
				continue
			}
			if offset == c.range.lowerBound && !c.range.isEmpty { return offset + delta }
			return c.range.lowerBound + delta + (bias == .after ? c.text.count : 0)
		}
		return offset + delta
	}
}
