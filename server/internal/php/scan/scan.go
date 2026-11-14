// Package scan extracts top-level declarations from PHP source without a full parse.
// It is the phase-0 spike for indexing speed; the real parser replaces it in phase 4a.
package scan

import (
	"bytes"
	"strings"
	"sync"

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
	op   byte // the operator byte for single-character operators, else 0
	text []byte
	off  int
}

// File scans one PHP file.
func File(src []byte) *Result {
	buf := tokPool.Get().(*[]tok)
	toks := significant(src, (*buf)[:0])
	defer func() { *buf = toks; tokPool.Put(buf) }()
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
			word := keyword(t.text)
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
				atStatementStart := prev.kind == lexer.EOF || isOp(prev, ";") || isOp(prev, "{") || isOp(prev, "}")
				if depth != nsDepth || class != "" || !atStatementStart {
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

// tokPool reuses token buffers across files; token slices dominated allocations.
var tokPool = sync.Pool{New: func() any { s := make([]tok, 0, 4096); return &s }}

var keywords = []string{"namespace", "use", "class", "interface", "trait", "enum", "function", "const", "case"}

// keyword returns the lower-case keyword the identifier matches (case-insensitively), or "".
func keyword(b []byte) string {
	for _, k := range keywords {
		if len(b) == len(k) && bytes.EqualFold(b, []byte(k)) {
			return k
		}
	}
	return ""
}

// significant drops whitespace, comments and inline HTML, appending to toks.
func significant(src []byte, toks []tok) []tok {
	l := lexer.New(src)
	for {
		t := l.Next()
		switch t.Kind {
		case lexer.EOF:
			return toks
		case lexer.Whitespace, lexer.Comment, lexer.DocComment, lexer.InlineHTML, lexer.OpenTag:
			continue
		case lexer.CloseTag:
			// "?>" ends a statement like ";"
			toks = append(toks, tok{lexer.Op, ';', []byte(";"), t.Start})
			continue
		}
		nt := tok{kind: t.Kind, text: t.Text(src), off: t.Start}
		if t.Kind == lexer.Op && len(nt.text) == 1 {
			nt.op = nt.text[0]
		}
		toks = append(toks, nt)
	}
}

func at(toks []tok, i int) tok {
	if i < 0 || i >= len(toks) {
		return tok{kind: lexer.EOF}
	}
	return toks[i]
}

func isOp(t tok, op string) bool {
	if len(op) == 1 {
		return t.op == op[0]
	}
	return t.kind == lexer.Op && string(t.text) == op
}
func isWord(t tok, w string) bool { return t.kind == lexer.Ident && bytes.EqualFold(t.text, []byte(w)) }
