import Testing
import MinorCore
@testable import LSPKit

struct HoverTests {
	@Test func markdownSplitsCodeFromProse() {
		let text = "```go\nfunc strings.ToUpper(s string) string\n```\n\n---\n\nToUpper returns s.\n\n- - -\n~~~\nplain\n~~~\n\n[`ToUpper` on pkg.go.dev](https://pkg.go.dev)"
		#expect(Markup.blocks(markdown: text) == [
			.code("func strings.ToUpper(s string) string", language: "go"),
			.markdown("ToUpper returns s."),
			.code("plain", language: nil),
			.markdown("[`ToUpper` on pkg.go.dev](https://pkg.go.dev)"),
		])
		// An unclosed fence runs to the end; inline backticks are prose.
		#expect(Markup.blocks(markdown: "Use `x`.\n```php\n$a") == [.markdown("Use `x`."), .code("$a", language: "php")])
	}

	@Test func everyContentShape() {
		#expect(Hover(["contents": ["kind": "plaintext", "value": "int x"]])?.contents.blocks == [.plain("int x")])
		#expect(Hover(["contents": ["language": "go", "value": "var x int"]])?.contents.blocks == [.code("var x int", language: "go")])
		#expect(Hover(["contents": ["**a**", ["language": "go", "value": "b"]]])?.contents.blocks == [.markdown("**a**"), .code("b", language: "go")])
		#expect(Hover(["contents": ["kind": "markdown", "value": "  \n"]]) == nil)
		#expect(Hover(.null) == nil)
	}

	@Test func signatureParametersAndActiveOne() throws {
		// String labels are found in order: the second "a" is the parameter after "ab".
		let json: JSONValue = [
			"signatures": [[
				"label": "f(ab int, a int)",
				"parameters": [["label": "ab int"], ["label": "a int", "documentation": "second"]],
			]],
			"activeParameter": 1,
		]
		let help = try #require(SignatureHelp(json))
		#expect(help.active.parameters.map(\.range) == [2..<8, 10..<15])
		#expect(help.activeParameter == 1)
		#expect(help.active.parameters[1].documentation?.blocks == [.markdown("second")])
		// Offsets in UTF-16; out of range means no active parameter; the signature's own wins.
		let offsets: JSONValue = ["signatures": [["label": "g(č int)", "parameters": [["label": [2, 7]]], "activeParameter": 0]], "activeParameter": 5]
		#expect(SignatureHelp(offsets)?.active.parameters.first?.range == 2..<7)
		#expect(SignatureHelp(offsets)?.activeParameter == 0)
		#expect(SignatureHelp(["signatures": [["label": "h(x)", "parameters": [["label": "x"]]]], "activeParameter": 3])?.activeParameter == nil)
		#expect(SignatureHelp(["signatures": []]) == nil)
		#expect(SignatureHelpSupport(["triggerCharacters": ["(", ","], "retriggerCharacters": [")"]])?.triggerCharacters == [0x28, 0x2C])
		#expect(SignatureHelpSupport(.bool(false)) == nil)
	}
}
