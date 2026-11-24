import XCTest
@testable import MinorIDE

final class HoverTests: XCTestCase {
	func testMarkdownSplitsCodeFromProse() {
		let text = "```go\nfunc strings.ToUpper(s string) string\n```\n\n---\n\nToUpper returns s.\n\n- - -\n~~~\nplain\n~~~\n\n[`ToUpper` on pkg.go.dev](https://pkg.go.dev)"
		XCTAssertEqual(Markup.blocks(markdown: text), [
			.code("func strings.ToUpper(s string) string", language: "go"),
			.markdown("ToUpper returns s."),
			.code("plain", language: nil),
			.markdown("[`ToUpper` on pkg.go.dev](https://pkg.go.dev)"),
		])
		// An unclosed fence runs to the end; inline backticks are prose.
		XCTAssertEqual(Markup.blocks(markdown: "Use `x`.\n```php\n$a"), [.markdown("Use `x`."), .code("$a", language: "php")])
	}

	func testEveryContentShape() {
		XCTAssertEqual(Hover(["contents": ["kind": "plaintext", "value": "int x"]])?.contents.blocks, [.plain("int x")])
		XCTAssertEqual(Hover(["contents": ["language": "go", "value": "var x int"]])?.contents.blocks, [.code("var x int", language: "go")])
		XCTAssertEqual(Hover(["contents": ["**a**", ["language": "go", "value": "b"]]])?.contents.blocks, [.markdown("**a**"), .code("b", language: "go")])
		XCTAssertNil(Hover(["contents": ["kind": "markdown", "value": "  \n"]]))
		XCTAssertNil(Hover(.null))
	}

	func testSignatureParametersAndActiveOne() throws {
		// String labels are found in order: the second "a" is the parameter after "ab".
		let json: JSONValue = [
			"signatures": [[
				"label": "f(ab int, a int)",
				"parameters": [["label": "ab int"], ["label": "a int", "documentation": "second"]],
			]],
			"activeParameter": 1,
		]
		let help = try XCTUnwrap(SignatureHelp(json))
		XCTAssertEqual(help.active.parameters.map(\.range), [2..<8, 10..<15])
		XCTAssertEqual(help.activeParameter, 1)
		XCTAssertEqual(help.active.parameters[1].documentation?.blocks, [.markdown("second")])
		// Offsets in UTF-16; out of range means no active parameter; the signature's own wins.
		let offsets: JSONValue = ["signatures": [["label": "g(č int)", "parameters": [["label": [2, 7]]], "activeParameter": 0]], "activeParameter": 5]
		XCTAssertEqual(SignatureHelp(offsets)?.active.parameters.first?.range, 2..<7)
		XCTAssertEqual(SignatureHelp(offsets)?.activeParameter, 0)
		XCTAssertNil(SignatureHelp(["signatures": [["label": "h(x)", "parameters": [["label": "x"]]]], "activeParameter": 3])?.activeParameter)
		XCTAssertNil(SignatureHelp(["signatures": []]))
		XCTAssertEqual(SignatureHelpSupport(["triggerCharacters": ["(", ","], "retriggerCharacters": [")"]])?.triggerCharacters, [0x28, 0x2C])
		XCTAssertNil(SignatureHelpSupport(.bool(false)))
	}
}
