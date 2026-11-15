import Foundation
import Testing
import TextEngine
@testable import Highlight

/// Golden tests: each Golden/<name>.<ext> is lexed line by line and compared with
/// Golden/<name>.<ext>.tokens ("line:column kind text" per token). MINORIDE_UPDATE_GOLDEN=1
/// rewrites the expected files; review the diff before committing.
struct GoldenTests {
	static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")

	static var cases: [String] {
		((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
			.filter { !$0.hasSuffix(".tokens") && $0 != ".DS_Store" }.sorted()
	}

	static func render(_ text: String, lexer: any Lexer) -> String {
		let rope = Rope(text)
		var state = LexState.start
		var out = ""
		for line in 0..<rope.lineCount {
			let bytes = rope.bytes(in: rope.lineRange(line))
			var tokens: [Token] = []
			lexer.lex(bytes[...], state: &state, tokens: &tokens)
			for t in tokens {
				let text = String(decoding: bytes[t.start..<t.end], as: UTF8.self)
				out += "\(line + 1):\(t.start + 1) \(t.kind.name) \(text)\n"
			}
		}
		return out
	}

	@Test(arguments: cases) func golden(_ name: String) throws {
		let source = Self.dir.appendingPathComponent(name)
		let lexer = try #require(Languages.lexer(forPath: name), "no lexer for \(name)")
		let actual = Self.render(try String(contentsOf: source, encoding: .utf8), lexer: lexer)
		let expectedURL = source.appendingPathExtension("tokens")
		if ProcessInfo.processInfo.environment["MINORIDE_UPDATE_GOLDEN"] == "1" {
			try actual.write(to: expectedURL, atomically: true, encoding: .utf8)
			return
		}
		let expected = try String(contentsOf: expectedURL, encoding: .utf8)
		#expect(actual == expected)
	}
}
