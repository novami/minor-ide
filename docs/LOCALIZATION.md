# Localization Engine

Target design (ADR-9). Until roadmap phase R2 is done, the current process in [translations.md](translations.md) applies (`L("…")`, `.strings`, `make l10n`).

## Files

```
Resources/Localization/
├─ en-US.json    source language, includes notes for translators
└─ cs-CZ.json    must always be complete
```

One file per language. Adding a language means adding one file and running the validator. No code changes. The bundle script generates `<lang>.lproj/InfoPlist.strings` (permission prompts) from the `infoPlist` namespace, and an empty `.lproj` per language so system-provided UI (standard menu items, open and save panels) follows the language.

## Format

```json
{
  "$meta": {
    "locale": "cs-CZ",
    "name": "Čeština",
    "englishName": "Czech",
    "fallback": "en-US",
    "plural": { "one": "i = 1 and v = 0", "few": "i = 2..4 and v = 0", "many": "v != 0" }
  },
  "project": {
    "delete": {
      "confirmation": { "text": "Smazat projekt „{projectName}“?" }
    }
  },
  "files": {
    "selected": {
      "one": "Vybrán {count} soubor",
      "few": "Vybrány {count} soubory",
      "many": "Vybráno {count} souboru",
      "other": "Vybráno {count} souborů"
    }
  },
  "docker": {
    "container": {
      "name": { "text": "kontejner", "variants": { "genitive": "kontejneru", "accusative": "kontejner" } }
    }
  }
}
```

- **Namespaces** are nested objects; the key path is the dotted path (`project.delete.confirmation`).
- **A message** is a string, an object with `text`, or an object with plural categories (`zero`, `one`, `two`, `few`, `many`, `other`; `other` is required).
- **Variants** (`variants`) hold explicit grammatical or context forms. The caller chooses a variant by name. There is no automatic suffixing of words; full sentence templates are preferred.
- **Notes**: `note` (only in `en-US.json`) describes where and how a text is used.
- **Parameters** are named:
  - `{projectName}`, `{path}`, `{version}` insert text;
  - `{count}` selects the plural category;
  - `{size, number}`, `{ratio, percent}`, `{date, date:short|medium|long}`, `{time, time}`, `{bytes, bytes}` format the value for the locale;
  - `{{` and `}}` are literal braces.
- **Plural rules** use the CLDR rule syntax (operands `n i v f t`, `and`, `or`, `=`, `!=`, ranges `2..4`, lists, `%`). A small evaluator runs them, so a new language needs no code. English: `one: "i = 1 and v = 0"`. Czech: `one`, `few` and `many` as above (`many` covers decimals, such as "1,5 souboru").

## Swift API

`minoride-l10n generate` creates typed accessors from `en-US.json` in `Sources/Localization/Generated/Strings.swift` (checked in):

```swift
Strings.project.delete.confirmation(projectName: name)   // String
Strings.files.selected(count: n)                          // plural
Strings.docker.container.name(.genitive)                  // variant
```

- A missing key or parameter is a compile error.
- Values are formatted with `Locale(identifier: meta.locale)` through Foundation format styles.
- The engine loads the selected language and its fallback once at startup; lookups are dictionary reads without allocation of new formats.
- Fallback order: selected language → its `fallback` → `en-US`. A missing translation in a debug build shows `⟦key⟧` and logs once.

## Language selection

Settings › General › Language: "System default" (matched against available files) or a specific language. The choice is stored in `settings.json` and written to the app's `AppleLanguages` default so system UI agrees. It applies after a restart, and the app offers to restart. Tests switch languages at runtime on the engine directly, without UI.

## Validation (`minoride-l10n validate`, part of `make test` and the release)

Validator checks:

- invalid JSON and duplicate keys (a custom parser that reports duplicates);
- keys missing in any language, and keys present only in a translation;
- unused keys: accessor references are scanned in `Sources/`;
- parameters: missing, unknown, or with a different format than in `en-US.json`;
- plural categories that the language's rule cannot produce, a missing `other`, or a missing category the rule can produce;
- variants declared in `en-US.json` but missing in a translation;
- `$meta` complete, and plural rules that parse.

The release fails when Czech is incomplete. The report prints completeness per language (`cs-CZ: 100 %, 812/812`).

## Content rules

- `en-US.json` holds simple, clear American English and is the source of truth; Czech uses natural grammar and typographic quotes („…“).
- Invariant values (paths, identifiers, versions) are always parameters, never concatenated.
- Help Book pages (`Resources/Help/<lang>.lproj`) stay as HTML per language; they are documents, not strings.

## Migration (phase R2)

1. Engine, plural evaluator, generator and validator in Swift. The Go tool `server/cmd/l10n` is removed.
2. A converter turns each `L("…")` and `LP(…)` into a key (`<area>.<context>.<slug>`). English comes from the source, Czech from `cs.lproj`. Plurals come from `.stringsdict`.
3. Keys and Czech wording are reviewed by hand, and the calls in the code are replaced.
4. `.strings`, `.stringsdict`, `translations.md` and the `make l10n-new` target are replaced by this document and `make l10n`.
