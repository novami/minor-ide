import XCTest
@testable import MinorIDE

final class PositionTests: XCTestCase {
	// "ž" = 2 bytes / 1 UTF-16 unit, "😀" = 4 bytes / 2 units.
	let rope = Rope("a\nžluť😀x\n")

	func testBothEncodings() {
		let x = 2 + "žluť😀".utf8.count
		XCTAssertEqual(rope.position(ofByte: x, encoding: .utf8), Position(line: 1, character: 10))
		XCTAssertEqual(rope.position(ofByte: x, encoding: .utf16), Position(line: 1, character: 6))
		XCTAssertEqual(rope.byteOffset(of: Position(line: 1, character: 10), encoding: .utf8), x)
		XCTAssertEqual(rope.byteOffset(of: Position(line: 1, character: 6), encoding: .utf16), x)
	}

	func testRoundTripsEveryBoundary() {
		let s = rope.string
		for i in s.unicodeScalars.indices {
			let b = s.utf8.distance(from: s.startIndex, to: i)
			for e in [PositionEncoding.utf8, .utf16] {
				XCTAssertEqual(rope.byteOffset(of: rope.position(ofByte: b, encoding: e), encoding: e), b)
			}
		}
	}

	func testClampsAndSnaps() {
		let lineEnd = 2 + "žluť😀x".utf8.count
		XCTAssertEqual(rope.byteOffset(of: Position(line: 1, character: 99), encoding: .utf16), lineEnd)
		XCTAssertEqual(rope.byteOffset(of: Position(line: 1, character: 99), encoding: .utf8), lineEnd)
		XCTAssertEqual(rope.byteOffset(of: Position(line: 9, character: 0), encoding: .utf8), rope.byteCount)
		// Inside "ž" (UTF-8) and inside the surrogate pair (UTF-16) → start of the character.
		XCTAssertEqual(rope.byteOffset(of: Position(line: 1, character: 1), encoding: .utf8), 2)
		XCTAssertEqual(rope.byteOffset(of: Position(line: 1, character: 5), encoding: .utf16), 2 + "žluť".utf8.count)
	}
}

final class GlobTests: XCTestCase {
	func testPatterns() {
		XCTAssertTrue(LSPGlob("**/*.go").matches("/p/a/b.go"))
		XCTAssertTrue(LSPGlob("**/*.go").matches("b.go"))
		XCTAssertFalse(LSPGlob("**/*.go").matches("/p/b.gox"))
		XCTAssertTrue(LSPGlob("**/{go.mod,go.sum,go.work}").matches("/p/go.sum"))
		XCTAssertTrue(LSPGlob("*.[ch]").matches("x.h"))
		XCTAssertFalse(LSPGlob("*.[!ch]").matches("x.h"))
		XCTAssertFalse(LSPGlob("*.go").matches("a/b.go"))
		XCTAssertTrue(LSPGlob("a?c").matches("abc"))
	}
}
