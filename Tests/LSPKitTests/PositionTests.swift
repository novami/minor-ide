import Testing
import TextEngine
@testable import LSPKit

struct PositionTests {
	// "ž" = 2 bytes / 1 UTF-16 unit, "😀" = 4 bytes / 2 units.
	let rope = Rope("a\nžluť😀x\n")

	@Test func bothEncodings() {
		let x = 2 + "žluť😀".utf8.count
		#expect(rope.position(ofByte: x, encoding: .utf8) == Position(line: 1, character: 10))
		#expect(rope.position(ofByte: x, encoding: .utf16) == Position(line: 1, character: 6))
		#expect(rope.byteOffset(of: Position(line: 1, character: 10), encoding: .utf8) == x)
		#expect(rope.byteOffset(of: Position(line: 1, character: 6), encoding: .utf16) == x)
	}

	@Test func roundTripsEveryBoundary() {
		let s = rope.string
		for i in s.unicodeScalars.indices {
			let b = s.utf8.distance(from: s.startIndex, to: i)
			for e in [PositionEncoding.utf8, .utf16] {
				#expect(rope.byteOffset(of: rope.position(ofByte: b, encoding: e), encoding: e) == b)
			}
		}
	}

	@Test func clampsAndSnaps() {
		let lineEnd = 2 + "žluť😀x".utf8.count
		#expect(rope.byteOffset(of: Position(line: 1, character: 99), encoding: .utf16) == lineEnd)
		#expect(rope.byteOffset(of: Position(line: 1, character: 99), encoding: .utf8) == lineEnd)
		#expect(rope.byteOffset(of: Position(line: 9, character: 0), encoding: .utf8) == rope.byteCount)
		// Inside "ž" (UTF-8) and inside the surrogate pair (UTF-16) → start of the character.
		#expect(rope.byteOffset(of: Position(line: 1, character: 1), encoding: .utf8) == 2)
		#expect(rope.byteOffset(of: Position(line: 1, character: 5), encoding: .utf16) == 2 + "žluť".utf8.count)
	}
}

struct GlobTests {
	@Test func patterns() {
		#expect(LSPGlob("**/*.go").matches("/p/a/b.go"))
		#expect(LSPGlob("**/*.go").matches("b.go"))
		#expect(!LSPGlob("**/*.go").matches("/p/b.gox"))
		#expect(LSPGlob("**/{go.mod,go.sum,go.work}").matches("/p/go.sum"))
		#expect(LSPGlob("*.[ch]").matches("x.h"))
		#expect(!LSPGlob("*.[!ch]").matches("x.h"))
		#expect(!LSPGlob("*.go").matches("a/b.go"))
		#expect(LSPGlob("a?c").matches("abc"))
	}
}
