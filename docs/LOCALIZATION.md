# Localization Engine

Design (ADR-9), in use since phase R2. Code: `Sources/Localization` (engine), `Sources/L10nTooling` and `Sources/L10nTool` (`minoride-l10n`).

## Adding or changing a text

1. Add the message to `Resources/Localization/en-US.json` and its translation to `cs-CZ.json`.
2. Run `make l10n` (regenerates `Strings.swift`) and use `Strings.<key>` in the code.
3. `make test` runs `make l10n-check`; commit the JSON files and `Strings.swift` together with the code.

Removing the last use of a key fails the check until the key is removed from all files.

## Files

```
Resources/Localization/
├─ en-US.json    source language, includes notes for translators
└─ cs-CZ.json    must always be complete
```

One file per language. Adding a language means adding one file and running the validator. No code changes. The bundle script (`minoride-l10n bundle`) copies the files into the app, generates `<lang>.lproj/InfoPlist.strings` (permission prompts) from the `infoPlist` namespace (`infoPlist.NSAppleEventsUsageDescription` …), and creates an empty `.lproj` per language so system-provided UI (standard menu items, open and save panels) follows the language.

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

- **Namespaces** are nested objects; the key path is the dotted path (`project.delete.confirmation`). Key segments are Swift identifiers; `text`, `note`, `variants` and the plural category names are reserved and cannot be keys.
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
- Parameter types: `{name}` takes any `CustomStringConvertible` (text, or a number without grouping such as a line number), `{name, number}` and `{name, bytes}` an integer, `{name, percent}` a `Double`, `{name, date…}` and `{name, time}` a `Date`. A plural message takes `count: Int`; `{count}` is written without grouping.
- English is built into `Strings.swift`, so `swift run` and tests show English without the bundle.
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

## Migration (phase R2, done)

All `L("…")` and `LP(…)` calls were converted to keys (`<area>.<slug>`; texts used in several places are in `common`, `format`, `connection`, `panel`, `find`, `menu`). The `.strings` and `.stringsdict` files, `translations.md` and the Go tool are removed.
