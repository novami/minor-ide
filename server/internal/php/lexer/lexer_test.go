package lexer

import (
	"fmt"
	"strings"
	"testing"
)

func lex(src string) string {
	l := New([]byte(src))
	var parts []string
	for {
		t := l.Next()
		if t.Kind == EOF {
			break
		}
		if t.Kind == Whitespace {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s(%s)", t.Kind, t.Text([]byte(src))))
	}
	return strings.Join(parts, " ")
}

func TestLexer(t *testing.T) {
	cases := []struct{ src, want string }{
		{"<html><?php echo $a?->b; ?>\n<p>",
			"InlineHTML(<html>) OpenTag(<?php ) Ident(echo) Variable($a) Op(?->) Ident(b) Op(;) CloseTag(?>\n) InlineHTML(<p>)"},
		{"<?= $x ?>", "OpenTag(<?=) Variable($x) CloseTag(?>)"},
		{"<?php use Foo\\Bar; \\strlen(namespace\\x);",
			"OpenTag(<?php ) Ident(use) Name(Foo\\Bar) Op(;) Name(\\strlen) Op(() Name(namespace\\x) Op()) Op(;)"},
		{"<?php #[Attr] // c ?>x", "OpenTag(<?php ) AttrOpen(#[) Ident(Attr) Op(]) Comment(// c ) CloseTag(?>) InlineHTML(x)"},
		{"<?php /** doc */ /*c*/ # h", "OpenTag(<?php ) DocComment(/** doc */) Comment(/*c*/) Comment(# h)"},
		{"<?php 0x1F 1_000 1.5e-3 .5 0b11",
			"OpenTag(<?php ) Number(0x1F) Number(1_000) Number(1.5e-3) Number(.5) Number(0b11)"},
		{"<?php 'a\\'b' \"c{$d}\\\"\" `ls`", "OpenTag(<?php ) String('a\\'b') String(\"c{$d}\\\"\") String(`ls`)"},
		{"<?php $a = <<<EOT\n  x {$y}\n  EOT;\n", "OpenTag(<?php ) Variable($a) Op(=) Heredoc(<<<EOT\n  x {$y}\n  EOT) Op(;)"},
		{"<?php $a = <<<'N'\nraw $x\nN;", "OpenTag(<?php ) Variable($a) Op(=) Heredoc(<<<'N'\nraw $x\nN) Op(;)"},
		{"<?php $a <<= 1 <=> $$b ??= fn() => 1;", "OpenTag(<?php ) Variable($a) Op(<<=) Number(1) Op(<=>) Op($) Variable($b) Op(??=) Ident(fn) Op(() Op()) Op(=>) Number(1) Op(;)"},
		{"<?php $příliš = 'ž';", "OpenTag(<?php ) Variable($příliš) Op(=) String('ž') Op(;)"},
		{"<?php \"unterminated", "OpenTag(<?php ) String(\"unterminated)"},
	}
	for _, c := range cases {
		if got := lex(c.src); got != c.want {
			t.Errorf("lex(%q)\n got %s\nwant %s", c.src, got, c.want)
		}
	}
}

// Every byte must belong to exactly one token, in order, for any input.
func FuzzLexerCoverage(f *testing.F) {
	f.Add("<?php class A { function b() { return <<<X\nx\nX; } }")
	f.Add("<html><?= $a ?> <?php #[ /* ")
	f.Fuzz(func(t *testing.T, src string) {
		l := New([]byte(src))
		pos := 0
		for i := 0; ; i++ {
			tok := l.Next()
			if tok.Start != pos || tok.End < tok.Start {
				t.Fatalf("gap or overlap at %d: %+v", pos, tok)
			}
			if tok.Kind == EOF {
				if pos != len(src) {
					t.Fatalf("EOF at %d, len %d", pos, len(src))
				}
				return
			}
			if tok.End == tok.Start {
				t.Fatalf("empty token %+v", tok)
			}
			pos = tok.End
		}
	})
}
