package l10n

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseRoundTrip(t *testing.T) {
	src := "/* header */\n// line comment\n" + TodoMarker + " \"Save\" = \"Save\";\n\"Say \\\"hi\\\"\\n\" = \"Řekni \\\"ahoj\\\"\\n\";\n"
	entries, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 || !entries[0].Todo || entries[1].Todo || entries[1].Value != "Řekni \"ahoj\"\n" {
		t.Fatalf("%+v", entries)
	}
	again, err := Parse(Format("", entries))
	if err != nil || len(again) != 2 || again[1].Value != entries[1].Value || !again[0].Todo {
		t.Fatalf("round trip: %+v %v", again, err)
	}
	if _, err := Parse(`"a" = "b"`); err == nil {
		t.Fatal("missing ; must fail")
	}
}

func TestPlaceholders(t *testing.T) {
	if got := strings.Join(Placeholders("Saved %d of %@ (100%%)"), ","); got != "@,d" {
		t.Fatal(got)
	}
	// reordering with positional specifiers is allowed
	if strings.Join(Placeholders("%2$@: %1$d"), ",") != strings.Join(Placeholders("%d: %@"), ",") {
		t.Fatal("positional specifiers must compare by type")
	}
}

func TestSyncAndCheck(t *testing.T) {
	root := t.TempDir()
	sources := filepath.Join(root, "Sources")
	resources := filepath.Join(root, "Resources")
	write := func(path, text string) {
		os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(sources, "App", "Menu.swift"), "/// e.g. L(\"Not a key\")\nm.item(L(\"Save\"), nil); alert(L(\"%d files\", n)); L(\"Old\")")
	write(filepath.Join(resources, "cs.lproj", "Localizable.strings"), "\"Save\" = \"Uložit\";\n\"Gone\" = \"Pryč\";\n")

	reports, err := Sync(sources, resources, "")
	if err != nil {
		t.Fatal(err)
	}
	cs := reports[0]
	if cs.Lang != "cs" || cs.Added != 2 || cs.Todo != 2 || len(cs.Obsolete) != 1 {
		t.Fatalf("%+v", cs)
	}
	// Czech is required: the two new keys are untranslated
	if p := Check(sources, resources, []string{"cs"}); len(p) != 2 {
		t.Fatalf("expected 2 problems, got %q", p)
	}
	// translate them, one with a wrong placeholder
	data, _ := os.ReadFile(filepath.Join(resources, "cs.lproj", "Localizable.strings"))
	fixed := strings.ReplaceAll(string(data), TodoMarker+" ", "")
	fixed = strings.Replace(fixed, `"%d files" = "%d files";`, `"%d files" = "souborů: %@";`, 1)
	fixed = strings.Replace(fixed, `"Old" = "Old";`, `"Old" = "Staré";`, 1)
	write(filepath.Join(resources, "cs.lproj", "Localizable.strings"), fixed)
	p := Check(sources, resources, []string{"cs"})
	if len(p) != 1 || !strings.Contains(p[0], "placeholders differ") {
		t.Fatalf("%q", p)
	}

	// a new language starts fully marked TODO and is not required
	if _, err := Sync(sources, resources, "de"); err != nil {
		t.Fatal(err)
	}
	de, _ := os.ReadFile(filepath.Join(resources, "de.lproj", "Localizable.strings"))
	if strings.Count(string(de), TodoMarker) != 3 {
		t.Fatalf("de:\n%s", de)
	}
}
