import Testing
@testable import TextEngine

struct RopeTests {
	@Test func basics() {
		var r = Rope("ahoj\nsvěte\n")
		#expect(r.lineCount == 3)
		#expect(r.string(in: r.lineRange(1)) == "světe")
		#expect(r.line(containing: 5) == 1)
		#expect(r.utf16Offset(ofByte: r.byteCount) == "ahoj\nsvěte\n".utf16.count)
		r.replace(0..<4, with: "čau 😀")
		#expect(r.string == "čau 😀\nsvěte\n")
		#expect(r.utf16Count == "čau 😀\nsvěte\n".utf16.count)
	}

	/// Random edits checked against a plain byte array, including multi-byte text and large pastes.
	@Test func randomEditsMatchReference() {
		var rng = SplitMix64(seed: 42)
		let pieces = ["a", "bc", "\n", "č", "😀", "line\n", String(repeating: "x", count: 3000), "ž\nš\n"]
		var reference: [UInt8] = []
		var rope = Rope()

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

			if step % 50 == 0 {
				#expect(rope.bytes(in: 0..<rope.byteCount) == reference)
				#expect(rope.validate())
				let s = String(decoding: reference, as: UTF8.self)
				#expect(rope.utf16Count == s.utf16.count)
				let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
				#expect(rope.lineCount == lines.count)
				let line = Int(rng.next() % UInt64(lines.count))
				#expect(rope.string(in: rope.lineRange(line)) == String(lines[line]))
				#expect(rope.line(containing: rope.offset(ofLine: line)) == line)
			}
		}
	}

	@Test func snapshotIsIndependent() {
		var r = Rope(String(repeating: "abc\n", count: 10_000))
		let snapshot = r
		r.replace(0..<r.byteCount, with: "")
		#expect(r.isEmpty)
		#expect(snapshot.lineCount == 10_001)
	}
}

/// Deterministic PRNG so failures are reproducible.
struct SplitMix64 {
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
