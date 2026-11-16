package search

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

func write(t *testing.T, root, rel, text string) {
	t.Helper()
	path := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func run(t *testing.T, o Options) ([]FileResult, Summary) {
	t.Helper()
	var got []FileResult
	s, err := Run(context.Background(), o, func(r FileResult) { got = append(got, r) })
	if err != nil {
		t.Fatal(err)
	}
	sort.Slice(got, func(i, j int) bool { return got[i].Path < got[j].Path })
	return got, s
}

func TestSearchRespectsGitignoreAndReportsLines(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".gitignore", "vendor/\n*.log\n!keep.log\n")
	write(t, root, "app/Home.php", "<?php\nclass Home {}\n// home Home HOME\n")
	write(t, root, "vendor/x/Home.php", "class Home {}\n")
	write(t, root, "debug.log", "Home\n")
	write(t, root, "keep.log", "Home\n")
	write(t, root, "bin.dat", "Home\x00\n")
	write(t, root, ".git/HEAD", "Home\n")
	write(t, root, "sub/.gitignore", "*.tmp\n")
	write(t, root, "sub/a.tmp", "Home\n")

	got, s := run(t, Options{Root: root, Query: "home"})
	paths := []string{}
	for _, r := range got {
		paths = append(paths, r.Path)
	}
	if strings.Join(paths, ",") != "app/Home.php,keep.log" {
		t.Fatalf("paths %v", paths)
	}
	home := got[0].Matches
	if len(home) != 2 || home[0].Line != 1 || home[1].Line != 2 || len(home[1].Ranges) != 3 || home[1].Ranges[2] != [2]int{13, 17} {
		t.Fatalf("matches %+v", home)
	}
	if s.Files != 2 || s.Matches != 5 {
		t.Fatalf("summary %+v", s)
	}

	got, _ = run(t, Options{Root: root, Query: "Home", CaseSensitive: true, WholeWord: true, Skip: []string{"keep.log"}})
	if len(got) != 1 || len(got[0].Matches[1].Ranges) != 1 {
		t.Fatalf("case/word %+v", got)
	}
	got, _ = run(t, Options{Root: root, Query: `^class (\w+)`, Regex: true})
	if len(got) != 1 || got[0].Matches[0].Ranges[0] != [2]int{0, 10} {
		t.Fatalf("regex %+v", got)
	}
}

func TestSearchCutsLongLinesAndLimitsMatches(t *testing.T) {
	root := t.TempDir()
	long := strings.Repeat("ž", 400) + "needle" + strings.Repeat("x", 1000)
	write(t, root, "long.txt", long+"\n"+strings.Repeat("needle\n", 50))
	got, s := run(t, Options{Root: root, Query: "needle", MaxMatches: 10})
	m := got[0].Matches[0]
	if len(m.Text) > maxLineText || m.Text[m.Ranges[0][0]:m.Ranges[0][1]] != "needle" || m.Column != 800-maxLineText/4 {
		t.Fatalf("long line %d %d %+v", len(m.Text), m.Column, m.Ranges)
	}
	if !s.Truncated || s.Matches != 10 {
		t.Fatalf("limit %+v", s)
	}
}

func TestGlob(t *testing.T) {
	cases := []struct {
		p, s string
		ok   bool
	}{
		{"*.go", "main.go", true}, {"*.go", "a/main.go", false}, {"a/**/b", "a/x/y/b", true}, {"a/**/b", "a/b", true},
		{"**/x", "x", true}, {"doc/**", "doc/a/b", true}, {"[a-c]?", "bz", true}, {"[!a]", "a", false}, {`\*`, "*", true},
	}
	for _, c := range cases {
		if glob(c.p, c.s) != c.ok {
			t.Errorf("glob(%q, %q) != %v", c.p, c.s, c.ok)
		}
	}
}

// BenchmarkFirstResult: 20 000 files, time until the first file with a match is reported
// (plan 2b: first results within 100 ms).
func BenchmarkFirstResult(b *testing.B) {
	root := b.TempDir()
	body := strings.Repeat("<?php\nnamespace App\\Model;\n\nfinal class Something\n{\n\tpublic function run(): void {}\n}\n", 20)
	for i := range 20000 {
		dir := filepath.Join(root, "vendor"+string(rune('a'+i%20)), "src", "m"+string(rune('a'+i%26)))
		os.MkdirAll(dir, 0o755)
		text := body
		if i%997 == 0 {
			text += "needle\n"
		}
		os.WriteFile(filepath.Join(dir, "F"+strings.Repeat("x", i%7)+string(rune('a'+i%26))+".php"+string(rune('0'+i%10))+"_"+strconv.Itoa(i)), []byte(text), 0o644)
	}
	b.ResetTimer()
	for range b.N {
		start := time.Now()
		var first time.Duration
		Run(context.Background(), Options{Root: root, Query: "needle"}, func(FileResult) {
			if first == 0 {
				first = time.Since(start)
			}
		})
		b.ReportMetric(float64(first.Microseconds())/1000, "ms-first")
		b.ReportMetric(float64(time.Since(start).Microseconds())/1000, "ms-all")
	}
}
