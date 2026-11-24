import XCTest
@testable import MinorIDE

final class SemanticTokensTests: XCTestCase {
	/// Relative groups become byte ranges per line; UTF-16 positions after "ž" shift by a byte.
	func testDecodesRelativeTokens() {
		let rope = Rope("ž := f(x)\nvar y\n")
		// "f" at character 5, "x" two later, "y" on the next line at 4; the last is past the text.
		let data = [0, 5, 1, 12, 0, 0, 2, 1, 7, 4, 1, 4, 1, 8, 1, 5, 0, 1, 8, 0]
		let lines = LanguageServer.decodeSemanticTokens(data, in: rope, encoding: .utf16)
		XCTAssertEqual(lines.count, 3)
		XCTAssertEqual(lines[0], [SemanticToken(start: 6, length: 1, type: 12, modifiers: 0), SemanticToken(start: 8, length: 1, type: 7, modifiers: 4)])
		XCTAssertEqual(lines[1], [SemanticToken(start: 4, length: 1, type: 8, modifiers: 1)])
		XCTAssertTrue(lines[2].isEmpty)
	}
}
