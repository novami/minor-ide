import Testing
@testable import Highlight

struct SemanticOverlayTests {
	@Test func namesAreRecolouredOthersKept() {
		// `x := "s" + Foo(y)`: string 5..<8, function 11..<14 guessed by the lexer.
		let base = [Token(5, 3, .string), Token(11, 3, .function)]
		let semantic = [Token(0, 1, .constant), Token(5, 3, .type), Token(11, 3, .type), Token(15, 1, .property)]
		#expect(Token.overlay(base, semantic) == [Token(0, 1, .constant), Token(5, 3, .string), Token(11, 3, .type), Token(15, 1, .property)])
	}

	@Test func partialOverlapSplitsTheLexerToken() {
		#expect(Token.overlay([Token(0, 6, .variable)], [Token(2, 2, .type)]) == [Token(0, 2, .variable), Token(2, 2, .type), Token(4, 2, .variable)])
	}

	@Test func semanticTypes() {
		#expect(TokenKind(semanticType: "method", modifiers: []) == .function)
		#expect(TokenKind(semanticType: "variable", modifiers: ["readonly"]) == .constant)
		#expect(TokenKind(semanticType: "variable", modifiers: []) == nil)
		#expect(TokenKind(semanticType: "keyword", modifiers: []) == nil)
	}
}
