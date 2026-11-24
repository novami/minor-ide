import XCTest
@testable import MinorIDE

final class SelectionTests: XCTestCase {
	func testMergesOverlapsAndKeepsPrimary() {
		let set = SelectionSet([
			Selection(anchor: 10, head: 6),
			Selection(caret: 2),
			Selection(anchor: 4, head: 8),
			Selection(caret: 8), // touches the end of a range
			Selection(anchor: 12, head: 14),
			Selection(anchor: 14, head: 16), // touching ranges stay apart
		], primary: 2)
		XCTAssertEqual(set.all, [Selection(caret: 2), Selection(anchor: 4, head: 10), Selection(anchor: 12, head: 14), Selection(anchor: 14, head: 16)])
		XCTAssertEqual(set.primaryIndex, 1)
	}

	func testMapsThroughMultiCaretTyping() {
		var rope = Rope("ab\ncd\nef")
		let set = SelectionSet([Selection(caret: 1), Selection(anchor: 3, head: 5), Selection(caret: 8)])
		let cs = ChangeSet(set.all.map { ($0.range, "XY") })
		cs.apply(to: &rope)
		XCTAssertEqual(rope.string, "aXYb\nXY\nefXY")
		// Ranges cover their replacement; the editor collapses them itself.
		XCTAssertEqual(set.mapped(through: cs).all.map(\.range), [3..<3, 5..<7, 12..<12])
	}

	/// Random selections and edits checked against a reference byte array.
	func testRandomChangeSetsMatchReference() {
		var rng = SplitMix64(seed: 7)
		let pieces = ["", "a", "\n", "č", "😀", "x\ny"]
		var reference = Array("ahoj\nsvěte\nčau 😀\n".utf8)
		var rope = Rope(bytes: reference)

		for _ in 0..<2000 {
			func boundary() -> Int {
				var o = Int(rng.next() % UInt64(reference.count + 1))
				while o > 0 && o < reference.count && reference[o] & 0xC0 == 0x80 { o -= 1 }
				return o
			}
			let raw = (0..<(1 + Int(rng.next() % 5))).map { _ in Selection(anchor: boundary(), head: boundary()) }
			let p = Int(rng.next() % UInt64(raw.count))
			let set = SelectionSet(raw, primary: p)
			XCTAssertTrue(set.primary.range.lowerBound <= raw[p].range.lowerBound && raw[p].range.upperBound <= set.primary.range.upperBound)
			for (a, b) in zip(set.all, set.all.dropFirst()) {
				XCTAssertTrue(a.range.upperBound <= b.range.lowerBound && !(a.range.upperBound == b.range.lowerBound && (a.isEmpty || b.isEmpty)))
			}

			let texts = set.all.map { _ in pieces[Int(rng.next() % UInt64(pieces.count))] }
			let cs = ChangeSet(Array(zip(set.all.map(\.range), texts)))
			for (s, t) in zip(set.all, texts).reversed() { reference.replaceSubrange(s.range, with: Array(t.utf8)) }
			cs.apply(to: &rope)
			XCTAssertEqual(rope.bytes(in: 0..<rope.byteCount), reference)

			// Each replaced range maps to exactly its new text.
			var delta = 0
			for (s, t) in zip(set.all, texts) {
				let start = s.range.lowerBound + delta
				XCTAssertEqual(cs.map(s.range.lowerBound, bias: .before), start)
				XCTAssertEqual(cs.map(s.range.upperBound, bias: .after), start + t.utf8.count)
				delta += t.utf8.count - s.range.count
			}
			for s in set.mapped(through: cs).all { XCTAssertTrue(s.range.upperBound <= rope.byteCount) }
		}
	}
}
