import XCTest
@testable import MinorIDE

final class PHPTokenizerTests: XCTestCase {
	static func tokens(_ bytes: [UInt8]) -> [PHPToken] {
		bytes.withUnsafeBufferPointer { buf in
			var lexer = PHPTokenizer(buf)
			var out: [PHPToken] = []
			while true {
				let t = lexer.next()
				if t.kind == .eof { return out }
				out.append(t)
			}
		}
	}

	static func lex(_ src: String) -> String {
		let bytes = Array(src.utf8)
		return tokens(bytes).filter { $0.kind != .whitespace }.map { t in
			"\(t.kind)(\(String(decoding: bytes[Int(t.start)..<Int(t.end)], as: UTF8.self)))"
		}.joined(separator: " ")
	}

	func testMainPaths() {
		let cases: [(String, String)] = [
			("<html><?php echo $a?->b; ?>\n<p>",
			 "inlineHTML(<html>) openTag(<?php ) ident(echo) variable($a) op(?->) ident(b) op(;) closeTag(?>\n) inlineHTML(<p>)"),
			("<?= $x ?>", "openTag(<?=) variable($x) closeTag(?>)"),
			("<?php use Foo\\Bar; \\strlen(namespace\\x);",
			 "openTag(<?php ) ident(use) name(Foo\\Bar) op(;) name(\\strlen) op(() name(namespace\\x) op()) op(;)"),
			("<?php #[Attr] // c ?>x", "openTag(<?php ) attrOpen(#[) ident(Attr) op(]) comment(// c ) closeTag(?>) inlineHTML(x)"),
			("<?php /** doc */ /*c*/ # h", "openTag(<?php ) docComment(/** doc */) comment(/*c*/) comment(# h)"),
			("<?php 0x1F 1_000 1.5e-3 .5 0b11 0o17", "openTag(<?php ) number(0x1F) number(1_000) number(1.5e-3) number(.5) number(0b11) number(0o17)"),
			("<?php $a = <<<EOT\n  x {$y}\n  EOT;\n", "openTag(<?php ) variable($a) op(=) heredoc(<<<EOT\n  x {$y}\n  EOT) op(;)"),
			("<?php $a = <<<'N'\nraw $x\nN;", "openTag(<?php ) variable($a) op(=) heredoc(<<<'N'\nraw $x\nN) op(;)"),
			("<?php $příliš = 'ž';", "openTag(<?php ) variable($příliš) op(=) string('ž') op(;)"),
			("<?php \"unterminated", "openTag(<?php ) string(\"unterminated)")
		]
		for (src, want) in cases { XCTAssertEqual(Self.lex(src), want, src) }
	}

	/// Every byte belongs to exactly one non-empty token, in order, for any input.
	private func assertCovers(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
		var pos = 0
		for t in Self.tokens(bytes) {
			XCTAssertEqual(Int(t.start), pos, file: file, line: line)
			XCTAssertGreaterThan(t.end, t.start, file: file, line: line)
			pos = Int(t.end)
		}
		XCTAssertEqual(pos, bytes.count, file: file, line: line)
	}

	func testTrailingBackslashStaysInBounds() {
		for src in ["<?php 'a\\", "<?php \"a\\", "<?php `\\"] { assertCovers(Array(src.utf8)) }
	}

	func testRandomMutationsCoverEveryByte() throws {
		let sample = try String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
			.appendingPathComponent("../HighlightTests/Golden/sample.php").standardized.path, encoding: .utf8)
		let seeds = [sample, "<?php class A { function b() { return <<<X\nx\nX; } }", "<html><?= $a ?> <?php #[ /* ", "<?php <<<'", "<?ph"]
		let alphabet = Array("<?php$\\'\"`#[]/*{}()\n\r\t ;:-><=!?.0x1e_aZ\u{00}\u{FF}".utf8)
		var rng = SystemRandomNumberGenerator()
		for _ in 0..<1500 {
			var bytes = Array(seeds.randomElement(using: &rng)!.utf8)
			for _ in 0..<Int.random(in: 1...12, using: &rng) {
				let at = Int.random(in: 0...bytes.count, using: &rng)
				if Bool.random(using: &rng) || bytes.isEmpty {
					bytes.insert(alphabet.randomElement(using: &rng)!, at: at)
				} else {
					bytes.remove(at: min(at, bytes.count - 1))
				}
			}
			assertCovers(bytes)
		}
	}
}
