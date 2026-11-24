import XCTest
@testable import MinorIDE

@MainActor
final class EditorSemanticTokensTests: XCTestCase {
	/// Tokens shift with edits on their line and with new lines; touched ones are dropped.
	func testTokensFollowEdits() {
		let a = EditorView(text: "foo(bar)\nbaz\n")
		a.document.setSemanticTokens([[Token(0, 3, .function), Token(4, 3, .type)], [Token(0, 3, .property)], []])
		a.replace([(0..<0, "x")]) // inserted before "foo": both move
		XCTAssertEqual(a.document.semanticLines[0], [Token(1, 3, .function), Token(5, 3, .type)])
		a.replace([(6..<6, "y")]) // inside "bar": dropped
		XCTAssertEqual(a.document.semanticLines[0], [Token(1, 3, .function)])
		a.replace([(0..<1, "\n\n")]) // two lines before: the rest moves down
		XCTAssertEqual(a.document.semanticLines.map(\.count), [0, 0, 1, 1, 0])
		XCTAssertEqual(a.document.semanticLines[2], [Token(0, 3, .function)])
		XCTAssertEqual(a.document.semanticLines[3], [Token(0, 3, .property)])
	}
}
