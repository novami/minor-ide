package search

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// rule is one pattern of a .gitignore file.
type rule struct {
	pattern  string
	negate   bool
	dirOnly  bool
	anchored bool // contains a slash: matched against the whole relative path
}

// ignoreFile holds the patterns of one .gitignore (or .git/info/exclude).
type ignoreFile []rule

func parseIgnore(text string) ignoreFile {
	var rules ignoreFile
	for _, line := range strings.FieldsFunc(text, func(r rune) bool { return r == '\n' || r == '\r' }) {
		if line == "" || line[0] == '#' {
			continue
		}
		for strings.HasSuffix(line, " ") && !strings.HasSuffix(line, "\\ ") {
			line = line[:len(line)-1]
		}
		var r rule
		if strings.HasPrefix(line, "!") {
			r.negate = true
			line = line[1:]
		} else if strings.HasPrefix(line, "\\") {
			line = line[1:]
		}
		if strings.HasSuffix(line, "/") {
			r.dirOnly = true
			line = line[:len(line)-1]
		}
		if line == "" {
			continue
		}
		r.anchored = strings.Contains(line, "/")
		r.pattern = strings.TrimPrefix(line, "/")
		rules = append(rules, r)
	}
	return rules
}

// match reports (ignored, decided): the last matching pattern decides.
func (f ignoreFile) match(rel string, isDir bool) (bool, bool) {
	name := rel[strings.LastIndexByte(rel, '/')+1:]
	for i := len(f) - 1; i >= 0; i-- {
		r := f[i]
		if r.dirOnly && !isDir {
			continue
		}
		subject := name
		if r.anchored {
			subject = rel
		}
		if glob(r.pattern, subject) {
			return !r.negate, true
		}
	}
	return false, false
}

// glob matches a whole string; * and ? stop at '/', ** crosses folders.
func glob(p, s string) bool {
	for len(p) > 0 {
		c := p[0]
		switch {
		case c == '*' && len(p) > 1 && p[1] == '*':
			rest := p[2:]
			if rest == "" {
				return true
			}
			rest = strings.TrimPrefix(rest, "/")
			for t := s; ; {
				if glob(rest, t) {
					return true
				}
				i := strings.IndexByte(t, '/')
				if i < 0 {
					return false
				}
				t = t[i+1:]
			}
		case c == '*':
			rest := p[1:]
			for t := s; ; t = t[1:] {
				if glob(rest, t) {
					return true
				}
				if t == "" || t[0] == '/' {
					return false
				}
			}
		}
		if s == "" {
			return false
		}
		switch c {
		case '?':
			if s[0] == '/' {
				return false
			}
		case '[':
			ok, next, valid := bracket(p, s[0])
			if !valid || !ok || s[0] == '/' {
				return false
			}
			p, s = next, s[1:]
			continue
		case '\\':
			if len(p) > 1 {
				p = p[1:]
			}
			if p[0] != s[0] {
				return false
			}
		default:
			if c != s[0] {
				return false
			}
		}
		p, s = p[1:], s[1:]
	}
	return s == ""
}

func bracket(p string, c byte) (matched bool, rest string, valid bool) {
	i := 1
	negate := false
	if i < len(p) && (p[i] == '!' || p[i] == '^') {
		negate = true
		i++
	}
	first := true
	for i < len(p) && (p[i] != ']' || first) {
		first = false
		if i+2 < len(p) && p[i+1] == '-' && p[i+2] != ']' {
			if p[i] <= c && c <= p[i+2] {
				matched = true
			}
			i += 3
		} else {
			if p[i] == c {
				matched = true
			}
			i++
		}
	}
	if i >= len(p) {
		return false, "", false
	}
	return matched != negate, p[i+1:], true
}

// ignoreSet reads .gitignore files on demand; deeper files win over higher ones and
// .git/info/exclude of the repository is the lowest priority.
type ignoreSet struct {
	root    string
	mu      sync.Mutex
	files   map[string]ignoreFile // folder relative to root ("" = root)
	exclude ignoreFile
}

func newIgnoreSet(root string) *ignoreSet {
	s := &ignoreSet{root: root, files: map[string]ignoreFile{}}
	if git := gitDir(root); git != "" {
		if data, err := os.ReadFile(filepath.Join(git, "info", "exclude")); err == nil {
			s.exclude = parseIgnore(string(data))
		}
	}
	return s
}

// gitDir finds the nearest .git folder at or above dir ("" outside a repository).
func gitDir(dir string) string {
	for {
		git := filepath.Join(dir, ".git")
		if st, err := os.Stat(git); err == nil {
			if st.IsDir() {
				return git
			}
			data, err := os.ReadFile(git)
			if err != nil || !strings.HasPrefix(string(data), "gitdir:") {
				return ""
			}
			path := strings.TrimSpace(strings.SplitN(string(data)[7:], "\n", 2)[0])
			if !filepath.IsAbs(path) {
				path = filepath.Join(dir, path)
			}
			return path
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

func (s *ignoreSet) patterns(folder string) ignoreFile {
	s.mu.Lock()
	f, ok := s.files[folder]
	s.mu.Unlock()
	if ok {
		return f
	}
	data, _ := os.ReadFile(filepath.Join(s.root, folder, ".gitignore"))
	f = parseIgnore(string(data))
	s.mu.Lock()
	s.files[folder] = f
	s.mu.Unlock()
	return f
}

// matches reports whether rel itself is ignored (its folders are checked by the walk).
func (s *ignoreSet) matches(rel string, isDir bool) bool {
	folder := rel
	for {
		if i := strings.LastIndexByte(folder, '/'); i >= 0 {
			folder = folder[:i]
		} else {
			folder = ""
		}
		sub := rel
		if folder != "" {
			sub = rel[len(folder)+1:]
		}
		if ignored, ok := s.patterns(folder).match(sub, isDir); ok {
			return ignored
		}
		if folder == "" {
			break
		}
	}
	ignored, _ := s.exclude.match(rel, isDir)
	return ignored
}
