import Testing
@testable import PHPKit

struct LexerTests {
	static func tokens(_ src: String) -> [PHPToken] {
		let bytes = Array(src.utf8)
		return bytes.withUnsafeBufferPointer { buf in
			var l = PHPLexer(buf)
			var out: [PHPToken] = []
			while true {
				let t = l.next()
				if t.kind == .eof { return out }
				out.append(t)
			}
		}
	}

	static func lex(_ src: String) -> String {
		let bytes = Array(src.utf8)
		return tokens(src).filter { $0.kind != .whitespace }.map { t in
			"\(t.kind)(\(String(decoding: bytes[Int(t.start)..<Int(t.end)], as: UTF8.self)))"
		}.joined(separator: " ")
	}

	@Test(arguments: [
		("<html><?php echo $a?->b; ?>\n<p>",
		 "inlineHTML(<html>) openTag(<?php ) ident(echo) variable($a) op(?->) ident(b) op(;) closeTag(?>\n) inlineHTML(<p>)"),
		("<?= $x ?>", "openTag(<?=) variable($x) closeTag(?>)"),
		("<?php use Foo\\Bar; \\strlen(namespace\\x);",
		 "openTag(<?php ) ident(use) name(Foo\\Bar) op(;) name(\\strlen) op(() name(namespace\\x) op()) op(;)"),
		("<?php #[Attr] // c ?>x", "openTag(<?php ) attrOpen(#[) ident(Attr) op(]) comment(// c ) closeTag(?>) inlineHTML(x)"),
		("<?php /** doc */ /*c*/ # h", "openTag(<?php ) docComment(/** doc */) comment(/*c*/) comment(# h)"),
		("<?php 0x1F 1_000 1.5e-3 .5 0b11", "openTag(<?php ) number(0x1F) number(1_000) number(1.5e-3) number(.5) number(0b11)"),
		("<?php 'a\\'b' \"c{$d}\\\"\" `ls`", "openTag(<?php ) string('a\\'b') string(\"c{$d}\\\"\") string(`ls`)"),
		("<?php $a = <<<EOT\n  x {$y}\n  EOT;\n", "openTag(<?php ) variable($a) op(=) heredoc(<<<EOT\n  x {$y}\n  EOT) op(;)"),
		("<?php $a = <<<'N'\nraw $x\nN;", "openTag(<?php ) variable($a) op(=) heredoc(<<<'N'\nraw $x\nN) op(;)"),
		("<?php $a <<= 1 <=> $$b ??= fn() => 1 |> f(...);",
		 "openTag(<?php ) variable($a) op(<<=) number(1) op(<=>) op($) variable($b) op(??=) ident(fn) op(() op()) op(=>) number(1) op(|>) ident(f) op(() op(...) op()) op(;)"),
		("<?php $příliš = 'ž';", "openTag(<?php ) variable($příliš) op(=) string('ž') op(;)"),
		("<?php \"unterminated", "openTag(<?php ) string(\"unterminated)"),
	])
	func lexes(_ src: String, _ want: String) {
		#expect(Self.lex(src) == want)
	}

	/// Every byte belongs to exactly one non-empty token, in order, for any input (random mutations).
	@Test func coversEveryByte() {
		let seeds = ["<?php class A { function b() { return <<<X\nx\nX; } }", "<html><?= $a ?> <?php #[ /* ", "<?php $x = \"a{$b}\\", "<?php <<<'", "<?ph"]
		let alphabet = Array("<?php$\\'\"`#[]/*{}()\n\r\t ;:-><=!?.0x1e_aZ\u{00}\u{FF}".utf8)
		var rng = SystemRandomNumberGenerator()
		for _ in 0..<3000 {
			var bytes = Array(seeds.randomElement(using: &rng)!.utf8)
			for _ in 0..<Int.random(in: 1...12, using: &rng) {
				let at = Int.random(in: 0...bytes.count, using: &rng)
				if Bool.random(using: &rng) || bytes.isEmpty {
					bytes.insert(alphabet.randomElement(using: &rng)!, at: at)
				} else {
					bytes.remove(at: min(at, bytes.count - 1))
				}
			}
			bytes.withUnsafeBufferPointer { buf in
				var l = PHPLexer(buf)
				var pos: Int32 = 0
				while true {
					let t = l.next()
					#expect(t.start == pos)
					if t.kind == .eof {
						#expect(Int(pos) == buf.count)
						return
					}
					#expect(t.end > t.start)
					pos = t.end
				}
			}
		}
	}
}
