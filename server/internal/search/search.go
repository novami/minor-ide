// Package search finds text in the files of a project folder: RE2 regular expressions or
// literal text, .gitignore respected, files read in parallel, results reported per file as
// soon as a file is done.
package search

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"sync"
	"sync/atomic"
)

// Options of one search.
type Options struct {
	Root          string   `json:"root"`
	Query         string   `json:"query"`
	Regex         bool     `json:"regex"`
	CaseSensitive bool     `json:"caseSensitive"`
	WholeWord     bool     `json:"wholeWord"`
	Skip          []string `json:"skip"`       // relative paths searched by the caller (unsaved files)
	MaxMatches    int      `json:"maxMatches"` // 0 = DefaultMaxMatches
}

// DefaultMaxMatches stops a search that would flood the result list.
const DefaultMaxMatches = 20000

// MaxFileSize skips bigger files (logs, dumps).
const MaxFileSize = 20 << 20

// maxLineText is how much of a long line is sent around its first match.
const maxLineText = 400

// Match is one line with matches; ranges are byte columns in Text, Column the byte column
// of Text's first byte in the line (non-zero when a long line was cut).
type Match struct {
	Line   int      `json:"line"`
	Column int      `json:"column"`
	Text   string   `json:"text"`
	Ranges [][2]int `json:"ranges"`
}

// FileResult are the matches in one file.
type FileResult struct {
	Path    string  `json:"path"` // relative to the root, '/'-separated
	Matches []Match `json:"matches"`
}

// Summary is returned when the search ends.
type Summary struct {
	Files     int  `json:"files"`
	Matches   int  `json:"matches"`
	Truncated bool `json:"truncated"`
	Cancelled bool `json:"cancelled"`
}

// ErrEmptyQuery is returned for an empty query.
var ErrEmptyQuery = errors.New("empty query")

type matcher struct {
	re      *regexp.Regexp
	literal []byte // case-sensitive literal fast path
}

func newMatcher(o Options) (*matcher, error) {
	if o.Query == "" {
		return nil, ErrEmptyQuery
	}
	if !o.Regex && o.CaseSensitive && !o.WholeWord {
		return &matcher{literal: []byte(o.Query)}, nil
	}
	expr := o.Query
	if !o.Regex {
		expr = regexp.QuoteMeta(expr)
	}
	if o.WholeWord {
		expr = `\b(?:` + expr + `)\b`
	}
	if !o.CaseSensitive {
		expr = `(?i)` + expr
	}
	expr = `(?m)` + expr // ^ and $ at line boundaries, like the editor's find
	re, err := regexp.Compile(expr)
	if err != nil {
		return nil, err
	}
	return &matcher{re: re}, nil
}

// find returns match offsets in data (at most limit).
func (m *matcher) find(data []byte, limit int) [][2]int {
	var out [][2]int
	if m.literal != nil {
		for at := 0; len(out) < limit; {
			i := bytes.Index(data[at:], m.literal)
			if i < 0 {
				break
			}
			out = append(out, [2]int{at + i, at + i + len(m.literal)})
			at += i + len(m.literal)
		}
		return out
	}
	for _, loc := range m.re.FindAllIndex(data, limit) {
		if loc[1] > loc[0] { // empty matches (^, a*) are not results
			out = append(out, [2]int{loc[0], loc[1]})
		}
	}
	return out
}

// Run searches o.Root and calls emit (serialised) for every file with matches.
func Run(ctx context.Context, o Options, emit func(FileResult)) (Summary, error) {
	m, err := newMatcher(o)
	if err != nil {
		return Summary{}, err
	}
	max := o.MaxMatches
	if max <= 0 {
		max = DefaultMaxMatches
	}
	skip := map[string]bool{}
	for _, p := range o.Skip {
		skip[p] = true
	}
	parent := ctx
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	paths := make(chan string, 256)
	var total atomic.Int64
	var files atomic.Int64
	var truncated atomic.Bool
	var emitMu sync.Mutex
	var wg sync.WaitGroup
	for range runtime.GOMAXPROCS(0) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for rel := range paths {
				if ctx.Err() != nil {
					continue
				}
				left := max - int(total.Load())
				if left <= 0 {
					truncated.Store(true)
					cancel()
					continue
				}
				res, n := searchFile(filepath.Join(o.Root, rel), rel, m, left)
				if n == 0 {
					continue
				}
				if int(total.Add(int64(n))) >= max {
					truncated.Store(true)
					cancel()
				}
				files.Add(1)
				emitMu.Lock()
				emit(res)
				emitMu.Unlock()
			}
		}()
	}
	walk(ctx, o.Root, newIgnoreSet(o.Root), func(rel string) {
		if !skip[rel] {
			paths <- rel
		}
	})
	close(paths)
	wg.Wait()
	s := Summary{Files: int(files.Load()), Matches: int(total.Load()), Truncated: truncated.Load()}
	s.Cancelled = parent.Err() != nil
	return s, nil
}

// searchFile returns the matches of one file grouped by line, and their count.
func searchFile(path, rel string, m *matcher, limit int) (FileResult, int) {
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() || st.Size() > MaxFileSize {
		return FileResult{}, 0
	}
	data, err := os.ReadFile(path)
	if err != nil || isBinary(data) {
		return FileResult{}, 0
	}
	found := m.find(data, limit)
	if len(found) == 0 {
		return FileResult{}, 0
	}
	res := FileResult{Path: rel}
	line, lineStart, scanned := 0, 0, 0
	for _, f := range found {
		// Advance the line counter to the match.
		for {
			i := bytes.IndexByte(data[scanned:f[0]], '\n')
			if i < 0 {
				break
			}
			line++
			lineStart = scanned + i + 1
			scanned = lineStart
		}
		scanned = f[0]
		end := bytes.IndexByte(data[lineStart:], '\n')
		lineEnd := len(data)
		if end >= 0 {
			lineEnd = lineStart + end
		}
		start, stop := f[0]-lineStart, min(f[1], lineEnd)-lineStart // a match across lines is cut at the line end
		if n := len(res.Matches); n > 0 && res.Matches[n-1].Line == line {
			last := &res.Matches[n-1]
			if s, e := start-last.Column, stop-last.Column; s >= 0 && e <= len(last.Text) {
				last.Ranges = append(last.Ranges, [2]int{s, e})
			}
			continue
		}
		text := data[lineStart:lineEnd]
		column := 0
		if len(text) > maxLineText {
			column = max(0, start-maxLineText/4)
			column = utf8Start(text, column)
			cut := utf8Start(text, min(len(text), column+maxLineText))
			text = text[column:cut]
		}
		text = bytes.TrimRight(text, "\r")
		s, e := start-column, min(stop-column, len(text))
		res.Matches = append(res.Matches, Match{Line: line, Column: column, Text: string(text), Ranges: [][2]int{{s, max(s, e)}}})
	}
	return res, len(found)
}

// utf8Start moves i back to the first byte of a UTF-8 character.
func utf8Start(b []byte, i int) int {
	for i > 0 && i < len(b) && b[i]&0xC0 == 0x80 {
		i--
	}
	return i
}

func isBinary(data []byte) bool {
	head := data
	if len(head) > 8000 {
		head = head[:8000]
	}
	return bytes.IndexByte(head, 0) >= 0
}

// hidden are never searched (version control internals, Finder metadata).
var hidden = map[string]bool{".git": true, ".DS_Store": true, ".svn": true, ".hg": true}

// walk calls visit with every file not ignored by Git, folders in sorted order.
func walk(ctx context.Context, root string, ign *ignoreSet, visit func(rel string)) {
	var rec func(rel string)
	rec = func(rel string) {
		entries, err := os.ReadDir(filepath.Join(root, rel))
		if err != nil {
			return
		}
		sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
		for _, e := range entries {
			if ctx.Err() != nil {
				return
			}
			name := e.Name()
			if hidden[name] {
				continue
			}
			child := name
			if rel != "" {
				child = rel + "/" + name
			}
			typ := e.Type()
			if typ&os.ModeSymlink != 0 {
				st, err := os.Stat(filepath.Join(root, child))
				if err != nil || st.IsDir() {
					continue // links to folders are not followed (cycles)
				}
				typ = 0
			}
			if typ.IsDir() {
				if !ign.matches(child, true) {
					rec(child)
				}
			} else if typ.IsRegular() && !ign.matches(child, false) {
				visit(child)
			}
		}
	}
	rec("")
}
