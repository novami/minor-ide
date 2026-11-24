import XCTest
@testable import MinorIDE

final class PHPHighlightTests: XCTestCase {
	private func kinds(_ line: String) -> [String: TokenKind] {
		var state = LexState.start
		var tokens: [Token] = []
		let bytes = Array(line.utf8)
		PHPLexer().lex(bytes[...], state: &state, tokens: &tokens)
		var out: [String: TokenKind] = [:]
		for t in tokens { out[String(decoding: bytes[t.start..<t.start + t.length], as: UTF8.self)] = t.kind }
		return out
	}

	func testMagicConstantsAndDie() {
		let k = kinds("<?php die(__CLASS__ . __line__);")
		XCTAssertEqual(k["die"], .keyword)
		XCTAssertEqual(k["__CLASS__"], .constant)
		XCTAssertEqual(k["__line__"], .constant)
	}
}
