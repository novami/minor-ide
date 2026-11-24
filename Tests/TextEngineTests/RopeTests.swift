import XCTest
@testable import MinorIDE

final class RopeTests: XCTestCase {
	func testBasics() {
		var r = Rope("ahoj\nsvěte\n")
		XCTAssertEqual(r.lineCount, 3)
		XCTAssertEqual(r.string(in: r.lineRange(1)), "světe")
		XCTAssertEqual(r.line(containing: 5), 1)
		XCTAssertEqual(r.utf16Offset(ofByte: r.byteCount), "ahoj\nsvěte\n".utf16.count)
		r.replace(0..<4, with: "čau 😀")
		XCTAssertEqual(r.string, "čau 😀\nsvěte\n")
		XCTAssertEqual(r.utf16Count, "čau 😀\nsvěte\n".utf16.count)
	}

	/// Random edits checked against a plain byte array, including multi-byte text and large pastes.
	func testRandomEditsMatchReference() {
		var rng = SplitMix64(seed: 42)
		let pieces = ["a", "bc", "\n", "č", "😀", "line\n", String(repeating: "x", count: 3000), "ž\nš\n"]
		var reference: [UInt8] = []
		var rope = Rope()
		var snapshots: [(Rope, [UInt8])] = [] // in-place mutation must never leak into earlier copies

		func boundary(_ i: Int) -> Int {
			var o = i
			while o > 0 && o < reference.count && reference[o] & 0xC0 == 0x80 { o -= 1 }
			return o
		}

		for step in 0..<4000 {
			let a = boundary(Int(rng.next() % UInt64(reference.count + 1)))
			let deleteLen = rng.next() % 4 == 0 ? Int(rng.next() % 200) : 0
			let b = boundary(min(reference.count, a + deleteLen))
			let text = rng.next() % 5 == 0 ? "" : pieces[Int(rng.next() % UInt64(pieces.count))]
			reference.replaceSubrange(a..<b, with: Array(text.utf8))
			rope.replace(a..<b, with: text)

			if step % 400 == 0 { snapshots.append((rope, reference)) }
			if step % 50 == 0 {
				XCTAssertEqual(rope.bytes(in: 0..<rope.byteCount), reference)
				XCTAssertTrue(rope.validate())
				let s = String(decoding: reference, as: UTF8.self)
				XCTAssertEqual(rope.utf16Count, s.utf16.count)
				let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
				XCTAssertEqual(rope.lineCount, lines.count)
				let line = Int(rng.next() % UInt64(lines.count))
				XCTAssertEqual(rope.string(in: rope.lineRange(line)), String(lines[line]))
				XCTAssertEqual(rope.line(containing: rope.offset(ofLine: line)), line)
			}
		}
		for (snapshot, bytes) in snapshots {
			XCTAssertEqual(snapshot.bytes(in: 0..<snapshot.byteCount), bytes)
			XCTAssertTrue(snapshot.validate())
		}
	}

	func testSnapshotIsIndependent() {
		var r = Rope(String(repeating: "abc\n", count: 10_000))
		let snapshot = r
		r.replace(0..<r.byteCount, with: "")
		XCTAssertTrue(r.isEmpty)
		XCTAssertEqual(snapshot.lineCount, 10_001)
	}
	func testUtf16ToByteOffsets() {
		let text = String(repeating: "čau 😀\n", count: 400) // several leaves, sequences split between them
		let r = Rope(text)
		var units = 0, bytes = 0
		for scalar in text.unicodeScalars {
			XCTAssertEqual(r.byteOffset(ofUTF16: units), bytes)
			if scalar.utf16.count == 2 { XCTAssertEqual(r.byteOffset(ofUTF16: units + 1), bytes) }
			units += scalar.utf16.count
			bytes += scalar.utf8.count
		}
		XCTAssertEqual(r.byteOffset(ofUTF16: units + 5), r.byteCount)
	}

	func testWordBoundaries() {
		let r = Rope("  $žluť_1 ->  x\n")
		XCTAssertEqual(r.wordEnd(after: 0), 3) // "$" is punctuation
		XCTAssertEqual(r.wordEnd(after: 3), 11)
		XCTAssertEqual(r.wordEnd(after: 11), 14)
		XCTAssertEqual(r.wordStart(before: 14), 12)
		XCTAssertEqual(r.wordStart(before: r.byteCount), 16)
		XCTAssertEqual(r.wordStart(before: 3), 2)
	}
}


/// Deterministic PRNG so failures are reproducible.
struct SplitMix64: RandomNumberGenerator {
	var state: UInt64
	init(seed: UInt64) { state = seed }
	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}
