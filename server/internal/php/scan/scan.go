// Package scan extracts top-level declarations from PHP source without a full parse.
// It is the phase-0 spike for indexing speed; the real parser replaces it in phase 4a.
package scan

import (
	"bytes"
	"strings"

	"github.com/novami/minor-ide/server/internal/php/lexer"
)

type Kind uint8

const (
	Class Kind = iota
	Interface
	Trait
	Enum
	Function
	Method
	Property
	Const
	EnumCase
)

var kindNames = [...]string{"class", "interface", "trait", "enum", "function", "method", "property", "const", "case"}

func (k Kind) String() string { return kindNames[k] }

type Decl struct {
	Kind   Kind
	Name   string // FQN for types/functions, Type::member for members
	Offset int
}

type Result struct {
	Namespace string
	Uses      []string
	Decls     []Decl
	// Unbalanced is true when braces did not close, a sign of a lexer or source problem.
	Unbalanced bool
}

type tok struct {
	kind lexer.Kind
	text []byte
	off  int
}

// File scans one PHP file.
func File(src []byte) *Result {
	toks := significant(src)
	r := &Result{}
	var (
		depth     int
		nsDepth   int    // brace depth of the current namespace body
		class     string // current class-like FQN
		classBody = -1   // brace depth inside the current class body
		pending   string // class name waiting for its "{"
		paren     int
	)
	qualify := func(name string) string {
		if r.Namespace == "" {
			return name
		}
		return r.Namespace + `\` + name
	}
	for i := 0; i < len(toks); i++ {
		t := toks[i]
		prev := at(toks, i-1)
		switch {
		case isOp(t, "{"):
			depth++
			if pending != "" {
				class, classBody, pending = pending, depth, ""
			}
		case isOp(t, "}"):
			if depth == classBody {
				class, classBody = "", -1
			}
			depth--
			if depth < nsDepth {
				nsDepth = depth
			}
		case isOp(t, "("):
			paren++
		case isOp(t, ")"):
			paren--
		case t.kind != lexer.Ident:
			if t.kind == lexer.Variable && depth == classBody && paren == 0 && class != "" {
				r.Decls = append(r.Decls, Decl{Property, class + "::" + string(t.text), t.off})
			}
		default:
			word := strings.ToLower(string(t.text))
			if isOp(prev, "::") || isOp(prev, "->") || isOp(prev, "?->") {
				continue // Foo::class, $x->class
			}
			switch word {
			case "namespace":
				if depth != nsDepth || isOp(at(toks, i+1), `\`) {
					continue
				}
				name := at(toks, i+1)
				switch {
				case name.kind == lexer.Ident || name.kind == lexer.Name:
					r.Namespace = strings.TrimPrefix(string(name.text), `\`)
					i++
				case isOp(name, "{"):
					r.Namespace = ""
				}
				if isOp(at(toks, i+1), "{") {
					nsDepth = depth + 1
				}
			case "use":
				if depth != nsDepth || class != "" {
					continue // closure use(...) or trait use
				}
				var b strings.Builder
				for i++; i < len(toks) && !isOp(toks[i], ";"); i++ {
					b.Write(toks[i].text)
					if toks[i].kind == lexer.Ident && at(toks, i+1).kind == lexer.Ident {
						b.WriteByte(' ')
					}
				}
				r.Uses = append(r.Uses, b.String())
			case "class", "interface", "trait", "enum":
				name := at(toks, i+1)
				if name.kind != lexer.Ident || isWord(prev, "new") || pending != "" {
					continue // anonymous class or "enum" used as a name
				}
				if word == "enum" && !(isOp(at(toks, i+2), "{") || isOp(at(toks, i+2), ":") || isWord(at(toks, i+2), "implements")) {
					continue
				}
				kind := map[string]Kind{"class": Class, "interface": Interface, "trait": Trait, "enum": Enum}[word]
				fqn := qualify(string(name.text))
				r.Decls = append(r.Decls, Decl{kind, fqn, name.off})
				pending = fqn
				i++
			case "function":
				j := i + 1
				if isOp(at(toks, j), "&") {
					j++
				}
				name := at(toks, j)
				if name.kind != lexer.Ident || !isOp(at(toks, j+1), "(") {
					continue // closure
				}
				switch {
				case class != "" && depth == classBody:
					r.Decls = append(r.Decls, Decl{Method, class + "::" + string(name.text), name.off})
				case class == "" && depth == nsDepth:
					r.Decls = append(r.Decls, Decl{Function, qualify(string(name.text)), name.off})
				}
				i = j
			case "const":
				if class != "" && depth != classBody || class == "" && depth != nsDepth {
					continue
				}
				// const [type] NAME = …, NAME2 = …; the name is the identifier before "=".
				for j := i + 1; j < len(toks) && !isOp(toks[j], ";"); j++ {
					if isOp(toks[j], "=") && toks[j-1].kind == lexer.Ident {
						name := string(toks[j-1].text)
						if class != "" {
							name = class + "::" + name
						} else {
							name = qualify(name)
						}
						r.Decls = append(r.Decls, Decl{Const, name, toks[j-1].off})
					}
				}
			case "case":
				if class != "" && depth == classBody && at(toks, i+1).kind == lexer.Ident {
					r.Decls = append(r.Decls, Decl{EnumCase, class + "::" + string(toks[i+1].text), toks[i+1].off})
				}
			}
		}
	}
	r.Unbalanced = depth != 0 || pending != ""
	return r
}

// significant drops whitespace, comments and inline HTML.
func significant(src []byte) []tok {
	l := lexer.New(src)
	toks := make([]tok, 0, len(src)/6)
	for {
		t := l.Next()
		switch t.Kind {
		case lexer.EOF:
			return toks
		case lexer.Whitespace, lexer.Comment, lexer.DocComment, lexer.InlineHTML, lexer.OpenTag:
			continue
		case lexer.CloseTag:
			// "?>" ends a statement like ";"
			toks = append(toks, tok{lexer.Op, []byte(";"), t.Start})
			continue
		}
		toks = append(toks, tok{t.Kind, t.Text(src), t.Start})
	}
}

func at(toks []tok, i int) tok {
	if i < 0 || i >= len(toks) {
		return tok{kind: lexer.EOF}
	}
	return toks[i]
}

func isOp(t tok, op string) bool  { return t.kind == lexer.Op && string(t.text) == op }
func isWord(t tok, w string) bool { return t.kind == lexer.Ident && bytes.EqualFold(t.text, []byte(w)) }
