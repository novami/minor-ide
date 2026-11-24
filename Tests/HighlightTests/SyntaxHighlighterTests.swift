import XCTest
@testable import MinorIDE

final class SyntaxHighlighterTests: XCTestCase {
	/// Tokens of every line lexed from the top, the reference for incremental relexing.
	static func reference(_ rope: Rope, _ lexer: any Lexer) -> [[Token]] {
		var state = LexState.start
		return (0..<rope.lineCount).map { line in
			var tokens: [Token] = []
			lexer.lex(rope.bytes(in: rope.lineRange(line))[...], state: &state, tokens: &tokens)
			return tokens
		}
	}

	func testRandomEditsMatchFullRelex() {
		var rng = SystemRandomNumberGenerator()
		let pieces = ["/*", "*/", "`", "\"", "\n", "x := 1\n", "// c\n", "func f() {\n", "}\n", "'a'", " "]
		var rope = Rope("package main\n\nfunc main() {\n\ts := `raw\nline`\n\t/* c */ x := 1\n}\n")
		let h = SyntaxHighlighter(lexer: GoLexer(), lineCount: rope.lineCount)
		h.eagerLimit = 3
		for step in 0..<400 {
			// Look at a random line now and then, as drawing does.
			if step % 3 == 0 { _ = h.tokens(line: Int.random(in: 0..<rope.lineCount, using: &rng), in: rope) }
			let a = Int.random(in: 0...rope.byteCount, using: &rng)
			let b = min(rope.byteCount, a + Int.random(in: 0...6, using: &rng))
			let text = Bool.random(using: &rng) ? pieces.randomElement(using: &rng)! : ""
			let firstLine = rope.line(containing: a), lastLine = rope.line(containing: b)
			let oldCount = rope.lineCount
			rope.replace(a..<b, with: text)
			h.edit(firstLine: firstLine, oldLastLine: lastLine, newLastLine: lastLine + rope.lineCount - oldCount, in: rope)
		}
		let expected = Self.reference(rope, GoLexer())
		for line in 0..<rope.lineCount {
			XCTAssertEqual(h.tokens(line: line, in: rope), expected[line], "line \(line)")
		}
	}

	func testOpeningACommentRecoloursBelowAndStopsWhenStatesMeet() {
		var rope = Rope("a\nb\nc\nd")
		let h = SyntaxHighlighter(lexer: GoLexer(), lineCount: rope.lineCount)
		_ = h.tokens(line: 3, in: rope)
		rope.replace(0..<0, with: "/*")
		XCTAssertEqual(h.edit(firstLine: 0, oldLastLine: 0, newLastLine: 0, in: rope), 0...3)
		rope.replace(rope.offset(ofLine: 1)..<rope.offset(ofLine: 1), with: "*/")
		XCTAssertEqual(h.edit(firstLine: 1, oldLastLine: 1, newLastLine: 1, in: rope), 1...3)
		rope.replace(rope.offset(ofLine: 2)..<rope.offset(ofLine: 2), with: "x")
		XCTAssertEqual(h.edit(firstLine: 2, oldLastLine: 2, newLastLine: 2, in: rope), 2...2)
	}

	func testLinesAcrossChunkBoundaries() {
		let text = "a\n" + String(repeating: "x", count: 70_000) + "\nb\n\nc"
		let rope = Rope(text)
		var lines: [String] = []
		SyntaxHighlighter.forEachLine(of: rope, from: 1, count: rope.lineCount - 1) { lines.append(String(decoding: $0, as: UTF8.self)) }
		XCTAssertEqual(lines, Array(text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().map(String.init)))
	}

	func testGapArrayKeepsOrder() {
		var g = GapArray(repeating: 0, count: 5)
		for i in 0..<5 { g[i] = i }
		g.replace(1..<3, with: 9, count: 3) // [0, 9, 9, 9, 3, 4]
		g.replace(5..<6, with: 7, count: 0) // [0, 9, 9, 9, 3]
		g.replace(0..<0, with: 8, count: 2) // [8, 8, 0, 9, 9, 9, 3]
		XCTAssertEqual((0..<g.count).map { g[$0] }, [8, 8, 0, 9, 9, 9, 3])
	}
}
