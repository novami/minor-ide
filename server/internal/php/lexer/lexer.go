// Package lexer tokenizes PHP 7.2–8.4 source. It never fails: unknown bytes
// become Illegal tokens so the parser can recover.
package lexer

import "bytes"

type Kind uint8

const (
	EOF Kind = iota
	InlineHTML
	OpenTag  // <?php, <?=, <?
	CloseTag // ?> including one directly following newline
	Whitespace
	Comment    // //, #, /* */
	DocComment // /** */
	Variable   // $name
	Ident      // identifiers and keywords
	Name       // qualified name containing a backslash: Foo\Bar, \Foo
	Number
	String  // '…', "…", `…` (interpolation is kept inside the token for now)
	Heredoc // <<<LABEL … LABEL, also nowdoc
	Op
	AttrOpen // #[
	Illegal
)

var kindNames = [...]string{"EOF", "InlineHTML", "OpenTag", "CloseTag", "Whitespace", "Comment", "DocComment",
	"Variable", "Ident", "Name", "Number", "String", "Heredoc", "Op", "AttrOpen", "Illegal"}

func (k Kind) String() string { return kindNames[k] }

type Token struct {
	Kind       Kind
	Start, End int // byte offsets
}

// Text returns the token's source bytes.
func (t Token) Text(src []byte) []byte { return src[t.Start:t.End] }

type Lexer struct {
	src   []byte
	pos   int
	inPHP bool
}

func New(src []byte) *Lexer { return &Lexer{src: src} }

// Next returns the next token. After EOF it keeps returning EOF.
func (l *Lexer) Next() Token {
	if l.pos >= len(l.src) {
		return Token{EOF, len(l.src), len(l.src)}
	}
	start := l.pos
	if !l.inPHP {
		return l.inlineHTML(start)
	}
	k := l.php()
	return Token{k, start, l.pos}
}

func (l *Lexer) inlineHTML(start int) Token {
	if n := openTagLen(l.src[l.pos:]); n > 0 {
		l.pos += n
		l.inPHP = true
		return Token{OpenTag, start, l.pos}
	}
	i := bytes.Index(l.src[l.pos:], []byte("<?"))
	for i >= 0 && openTagLen(l.src[l.pos+i:]) == 0 {
		next := bytes.Index(l.src[l.pos+i+2:], []byte("<?"))
		if next < 0 {
			i = -1
			break
		}
		i += 2 + next
	}
	if i < 0 {
		l.pos = len(l.src)
	} else {
		l.pos += i
	}
	return Token{InlineHTML, start, l.pos}
}

func openTagLen(b []byte) int {
	if len(b) < 2 || b[0] != '<' || b[1] != '?' {
		return 0
	}
	if len(b) >= 5 && bytes.EqualFold(b[2:5], []byte("php")) {
		if len(b) == 5 {
			return 5
		}
		if isSpace(b[5]) {
			if b[5] == '\r' && len(b) > 6 && b[6] == '\n' {
				return 7
			}
			return 6
		}
		return 0
	}
	if len(b) >= 3 && b[2] == '=' {
		return 3
	}
	return 2
}

func (l *Lexer) php() Kind {
	src, c := l.src, l.src[l.pos]
	switch {
	case isSpace(c):
		for l.pos < len(src) && isSpace(src[l.pos]) {
			l.pos++
		}
		return Whitespace
	case c == '?' && l.peek(1) == '>':
		l.pos += 2
		if l.peek(0) == '\n' {
			l.pos++
		} else if l.peek(0) == '\r' && l.peek(1) == '\n' {
			l.pos += 2
		}
		l.inPHP = false
		return CloseTag
	case c == '#' && l.peek(1) == '[':
		l.pos += 2
		return AttrOpen
	case c == '#' || (c == '/' && l.peek(1) == '/'):
		l.lineComment()
		return Comment
	case c == '/' && l.peek(1) == '*':
		doc := l.peek(2) == '*' && isSpace(l.peek(3))
		end := bytes.Index(src[l.pos+2:], []byte("*/"))
		if end < 0 {
			l.pos = len(src)
		} else {
			l.pos += 2 + end + 2
		}
		if doc {
			return DocComment
		}
		return Comment
	case c == '$' && isIdentStart(l.peek(1)):
		l.pos++
		l.ident()
		return Variable
	case isIdentStart(c):
		l.ident()
		if l.nameContinues() {
			l.name()
			return Name
		}
		return Ident
	case c == '\\' && isIdentStart(l.peek(1)):
		l.name()
		return Name
	case isDigit(c) || (c == '.' && isDigit(l.peek(1))):
		l.number()
		return Number
	case c == '\'' || c == '"' || c == '`':
		l.quoted(c)
		return String
	case c == '<' && l.peek(1) == '<' && l.peek(2) == '<':
		if l.heredoc() {
			return Heredoc
		}
	}
	if n := opLen(src[l.pos:]); n > 0 {
		l.pos += n
		return Op
	}
	l.pos++
	return Illegal
}

func (l *Lexer) peek(n int) byte {
	if l.pos+n < len(l.src) {
		return l.src[l.pos+n]
	}
	return 0
}

func (l *Lexer) lineComment() {
	for l.pos < len(l.src) {
		c := l.src[l.pos]
		if c == '\n' || c == '\r' {
			return
		}
		if c == '?' && l.peek(1) == '>' {
			return // ?> ends a line comment
		}
		l.pos++
	}
}

func (l *Lexer) ident() {
	for l.pos < len(l.src) && isIdentChar(l.src[l.pos]) {
		l.pos++
	}
}

func (l *Lexer) nameContinues() bool {
	return l.peek(0) == '\\' && isIdentStart(l.peek(1))
}

func (l *Lexer) name() {
	for l.peek(0) == '\\' && isIdentStart(l.peek(1)) {
		l.pos++
		l.ident()
	}
}

func (l *Lexer) number() {
	src := l.src
	if src[l.pos] == '0' && l.pos+1 < len(src) {
		switch src[l.pos+1] | 0x20 {
		case 'x', 'b', 'o':
			l.pos += 2
			for l.pos < len(src) && (isHex(src[l.pos]) || src[l.pos] == '_') {
				l.pos++
			}
			return
		}
	}
	digits := func() {
		for l.pos < len(src) && (isDigit(src[l.pos]) || (src[l.pos] == '_' && isDigit(l.peek(1)))) {
			l.pos++
		}
	}
	digits()
	// "1." without following digits is valid PHP but rare; it lexes as 1 and the "." operator.
	if l.peek(0) == '.' && isDigit(l.peek(1)) {
		l.pos++
		digits()
	}
	if c := l.peek(0) | 0x20; c == 'e' {
		n := 1
		if l.peek(1) == '+' || l.peek(1) == '-' {
			n = 2
		}
		if isDigit(l.peek(n)) {
			l.pos += n
			digits()
		}
	}
}

func (l *Lexer) quoted(q byte) {
	l.pos++
	for l.pos < len(l.src) {
		c := l.src[l.pos]
		if c == '\\' {
			l.pos += 2
			continue
		}
		l.pos++
		if c == q {
			return
		}
	}
	l.pos = len(l.src)
}

// heredoc consumes <<<LABEL … LABEL (PHP 7.3 flexible syntax). It returns false if
// this is not a heredoc start, leaving the position unchanged.
func (l *Lexer) heredoc() bool {
	src := l.src
	p := l.pos + 3
	for p < len(src) && (src[p] == ' ' || src[p] == '\t') {
		p++
	}
	quote := byte(0)
	if p < len(src) && (src[p] == '\'' || src[p] == '"') {
		quote = src[p]
		p++
	}
	ls := p
	for p < len(src) && isIdentChar(src[p]) {
		p++
	}
	if p == ls || !isIdentStart(src[ls]) {
		return false
	}
	label := src[ls:p]
	if quote != 0 {
		if p >= len(src) || src[p] != quote {
			return false
		}
		p++
	}
	if p < len(src) && src[p] == '\r' {
		p++
	}
	if p >= len(src) || src[p] != '\n' {
		return false
	}
	p++
	for p < len(src) {
		q := p
		for q < len(src) && (src[q] == ' ' || src[q] == '\t') {
			q++
		}
		if bytes.HasPrefix(src[q:], label) && (q+len(label) >= len(src) || !isIdentChar(src[q+len(label)])) {
			l.pos = q + len(label)
			return true
		}
		nl := bytes.IndexByte(src[p:], '\n')
		if nl < 0 {
			break
		}
		p += nl + 1
	}
	l.pos = len(src)
	return true
}

var ops = []string{
	"<<=", ">>=", "**=", "...", "<=>", "===", "!==", "??=", "?->",
	"<<", ">>", "**", "++", "--", "->", "=>", "::", "==", "!=", "<>", "<=", ">=",
	"&&", "||", "??", "+=", "-=", "*=", "/=", ".=", "%=", "&=", "|=", "^=",
}

// opsByFirst indexes multi-character operators by their first byte, longest first.
var opsByFirst = func() (t [256][]string) {
	for _, op := range ops {
		t[op[0]] = append(t[op[0]], op)
	}
	return
}()

func opLen(b []byte) int {
	for _, op := range opsByFirst[b[0]] {
		if len(b) >= len(op) && string(b[:len(op)]) == op {
			return len(op)
		}
	}
	switch b[0] {
	case '+', '-', '*', '/', '%', '=', '<', '>', '!', '.', '&', '|', '^', '~', '?', ':', ';', ',',
		'(', ')', '[', ']', '{', '}', '@', '$', '\\':
		return 1
	}
	return 0
}

const (
	clsSpace = 1 << iota
	clsDigit
	clsIdentStart
	clsHex
)

// charClass is a lookup table; the lexer's hot loops test one byte at a time.
var charClass = func() (t [256]uint8) {
	for c := 0; c < 256; c++ {
		b := byte(c)
		if b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\v' || b == '\f' {
			t[c] |= clsSpace
		}
		if b >= '0' && b <= '9' {
			t[c] |= clsDigit | clsHex
		}
		if b == '_' || (b|0x20 >= 'a' && b|0x20 <= 'z') || b >= 0x80 {
			t[c] |= clsIdentStart
		}
		if b|0x20 >= 'a' && b|0x20 <= 'f' {
			t[c] |= clsHex
		}
	}
	return
}()

func isSpace(c byte) bool      { return charClass[c]&clsSpace != 0 }
func isDigit(c byte) bool      { return charClass[c]&clsDigit != 0 }
func isHex(c byte) bool        { return charClass[c]&clsHex != 0 }
func isIdentStart(c byte) bool { return charClass[c]&clsIdentStart != 0 }
func isIdentChar(c byte) bool  { return charClass[c]&(clsIdentStart|clsDigit) != 0 }
