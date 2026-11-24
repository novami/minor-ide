import XCTest
@testable import MinorIDE

final class SemanticOverlayTests: XCTestCase {
	func testNamesAreRecolouredOthersKept() {
		// `x := "s" + Foo(y)`: string 5..<8, function 11..<14 guessed by the lexer.
		let base = [Token(5, 3, .string), Token(11, 3, .function)]
		let semantic = [Token(0, 1, .constant), Token(5, 3, .type), Token(11, 3, .type), Token(15, 1, .property)]
		XCTAssertEqual(Token.overlay(base, semantic), [Token(0, 1, .constant), Token(5, 3, .string), Token(11, 3, .type), Token(15, 1, .property)])
	}

	func testPartialOverlapSplitsTheLexerToken() {
		XCTAssertEqual(Token.overlay([Token(0, 6, .variable)], [Token(2, 2, .type)]), [Token(0, 2, .variable), Token(2, 2, .type), Token(4, 2, .variable)])
	}

	func testSemanticTypes() {
		XCTAssertEqual(TokenKind(semanticType: "method", modifiers: []), .function)
		XCTAssertEqual(TokenKind(semanticType: "variable", modifiers: ["readonly"]), .constant)
		XCTAssertNil(TokenKind(semanticType: "variable", modifiers: []))
		XCTAssertNil(TokenKind(semanticType: "keyword", modifiers: []))
	}
}
