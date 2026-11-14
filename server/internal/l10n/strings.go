// Package l10n keeps the app's translations in sync with the Swift sources.
//
// English (en, US spelling) is the development language: its Localizable.strings is generated
// from every L("…") call in Sources/. Other languages get missing keys added with the English
// text and a TODO marker; Check fails while a required language (Czech) has TODOs, missing keys
// or placeholders that differ from English.
package l10n

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Entry is one key with its value and the source files that use it.
type Entry struct {
	Key, Value string
	Todo       bool     // value not translated yet
	Files      []string // where the key is used (only for the English file)
	// Plural keys come from LP("other", one: "one", n): Key/Value is the English plural,
	// One the English singular. In .strings files they appear as "key|category" entries.
	Plural bool
	One    string
}

// TodoMarker precedes untranslated entries in a .strings file.
const TodoMarker = "/* TODO translate */"

var (
	callRe   = regexp.MustCompile(`\bL\(\s*"((?:[^"\\]|\\.)*)"`)
	pluralRe = regexp.MustCompile(`\bLP\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*one:\s*"((?:[^"\\]|\\.)*)"`)
)

// Extract finds L("…") keys in .swift files under dir, in first-use order grouped by file.
func Extract(dir string) ([]Entry, error) {
	byKey := map[string]*Entry{}
	var order []string
	err := filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".swift") {
			return err
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, path)
		code := withoutLineComments(string(src))
		add := func(e Entry) error {
			if strings.Contains(e.Key, "|") {
				return fmt.Errorf("%s: %q: \"|\" is reserved for plural forms", rel, e.Key)
			}
			if old, ok := byKey[e.Key]; ok {
				if old.Plural != e.Plural {
					return fmt.Errorf("%s: %q is used both with L and LP", rel, e.Key)
				}
				if !contains(old.Files, rel) {
					old.Files = append(old.Files, rel)
				}
				return nil
			}
			byKey[e.Key] = &e
			order = append(order, e.Key)
			return nil
		}
		for _, m := range callRe.FindAllStringSubmatch(code, -1) {
			key := unescapeSwift(m[1])
			if err := add(Entry{Key: key, Value: key, Files: []string{rel}}); err != nil {
				return err
			}
		}
		for _, m := range pluralRe.FindAllStringSubmatch(code, -1) {
			key := unescapeSwift(m[1])
			if err := add(Entry{Key: key, Value: key, One: unescapeSwift(m[2]), Plural: true, Files: []string{rel}}); err != nil {
				return err
			}
		}
		return nil
	})
	entries := make([]Entry, len(order))
	for i, k := range order {
		entries[i] = *byKey[k]
	}
	return entries, err
}

// Parse reads a .strings file: "key" = "value"; with /* */ and // comments.
// An entry directly preceded by TodoMarker is marked Todo.
func Parse(text string) ([]Entry, error) {
	var out []Entry
	todo := false
	s := text
	line := 1
	for len(s) > 0 {
		switch {
		case s[0] == '\n':
			line++
			s = s[1:]
		case s[0] == ' ' || s[0] == '\t' || s[0] == '\r':
			s = s[1:]
		case strings.HasPrefix(s, "/*"):
			end := strings.Index(s, "*/")
			if end < 0 {
				return nil, fmt.Errorf("line %d: unterminated comment", line)
			}
			if s[:end+2] == TodoMarker {
				todo = true
			}
			line += strings.Count(s[:end+2], "\n")
			s = s[end+2:]
		case strings.HasPrefix(s, "//"):
			end := strings.IndexByte(s, '\n')
			if end < 0 {
				end = len(s)
			}
			s = s[end:]
		case s[0] == '"':
			key, rest, err := quoted(s)
			if err != nil {
				return nil, fmt.Errorf("line %d: %v", line, err)
			}
			rest = strings.TrimLeft(rest, " \t")
			if !strings.HasPrefix(rest, "=") {
				return nil, fmt.Errorf("line %d: expected = after %q", line, key)
			}
			rest = strings.TrimLeft(rest[1:], " \t")
			value, rest, err := quoted(rest)
			if err != nil {
				return nil, fmt.Errorf("line %d: %v", line, err)
			}
			rest = strings.TrimLeft(rest, " \t")
			if !strings.HasPrefix(rest, ";") {
				return nil, fmt.Errorf("line %d: expected ; after %q", line, key)
			}
			out = append(out, Entry{Key: key, Value: value, Todo: todo})
			todo = false
			s = rest[1:]
		default:
			return nil, fmt.Errorf("line %d: unexpected %q", line, s[:1])
		}
	}
	return out, nil
}

func quoted(s string) (string, string, error) {
	var b strings.Builder
	for i := 1; i < len(s); i++ {
		switch s[i] {
		case '\\':
			if i+1 >= len(s) {
				return "", "", fmt.Errorf("unterminated string")
			}
			i++
			switch s[i] {
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			default:
				b.WriteByte(s[i])
			}
		case '"':
			return b.String(), s[i+1:], nil
		default:
			b.WriteByte(s[i])
		}
	}
	return "", "", fmt.Errorf("unterminated string")
}

func escape(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`, "\t", `\t`)
	return r.Replace(s)
}

// unescapeSwift handles the escapes that appear in Swift string literals used as keys.
func unescapeSwift(s string) string {
	r := strings.NewReplacer(`\"`, `"`, `\\`, `\`, `\n`, "\n", `\t`, "\t")
	return r.Replace(s)
}

// Format writes entries; English entries carry a comment with the files using them.
func Format(header string, entries []Entry) string {
	var b strings.Builder
	b.WriteString(header)
	lastFiles := ""
	for _, e := range entries {
		if files := strings.Join(e.Files, ", "); files != "" && files != lastFiles {
			fmt.Fprintf(&b, "\n/* %s */\n", files)
			lastFiles = files
		}
		if e.Todo {
			b.WriteString(TodoMarker + " ")
		}
		fmt.Fprintf(&b, "\"%s\" = \"%s\";\n", escape(e.Key), escape(e.Value))
	}
	return b.String()
}

var placeholderRe = regexp.MustCompile(`%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaA%]`)

// Placeholders returns the sorted conversion types of s ("%1$@ %d" → ["@", "d"]), so a
// translation may reorder arguments with positional specifiers but not change their types.
func Placeholders(s string) []string {
	var out []string
	for _, p := range placeholderRe.FindAllString(s, -1) {
		if p != "%%" {
			out = append(out, p[len(p)-1:])
		}
	}
	sort.Strings(out)
	return out
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// withoutLineComments blanks lines that are // or /// comments, so examples in
// documentation do not become keys.
func withoutLineComments(src string) string {
	lines := strings.Split(src, "\n")
	for i, l := range lines {
		if strings.HasPrefix(strings.TrimSpace(l), "//") {
			lines[i] = ""
		}
	}
	return strings.Join(lines, "\n")
}
