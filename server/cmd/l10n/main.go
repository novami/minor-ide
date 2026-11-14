// Command l10n keeps translations in sync (run from the repository root via make):
//
//	l10n sync            regenerate English, add new keys to all languages (TODO), drop obsolete ones
//	l10n new <lang>      add a language (e.g. de, sk, pt-BR) with all keys marked TODO
//	l10n check           fail on stale English, missing keys, placeholder mismatches,
//	                     and untranslated entries in required languages (-require cs)
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/novami/minor-ide/server/internal/l10n"
)

func main() {
	sources := flag.String("sources", "Sources", "Swift sources with L(\"…\") calls")
	resources := flag.String("resources", "Resources", "directory with <lang>.lproj folders")
	require := flag.String("require", "cs", "comma-separated languages that must be fully translated")
	flag.Parse()

	switch flag.Arg(0) {
	case "sync", "new":
		lang := ""
		if flag.Arg(0) == "new" {
			lang = flag.Arg(1)
			if lang == "" || strings.ContainsAny(lang, "/. ") {
				fail("usage: l10n new <lang>, e.g. l10n new de")
			}
		}
		reports, err := l10n.Sync(*sources, *resources, lang)
		if err != nil {
			fail(err.Error())
		}
		for _, r := range reports {
			fmt.Printf("%-6s added %d, untranslated %d", r.Lang, r.Added, r.Todo)
			if len(r.Obsolete) > 0 {
				fmt.Printf(", removed obsolete: %q", r.Obsolete)
			}
			if len(r.PlaceholderMismatch) > 0 {
				fmt.Printf(", PLACEHOLDERS DIFFER: %q", r.PlaceholderMismatch)
			}
			fmt.Println()
		}
	case "check":
		problems := l10n.Check(*sources, *resources, strings.Split(*require, ","))
		for _, p := range problems {
			fmt.Println(p)
		}
		if len(problems) > 0 {
			fail(fmt.Sprintf("%d translation problem(s)", len(problems)))
		}
		fmt.Println("translations OK")
	default:
		fail("usage: l10n sync | new <lang> | check [-require cs]")
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "l10n:", msg)
	os.Exit(1)
}
