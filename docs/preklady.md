# Překlady

Výchozí jazyk aplikace je **angličtina (US)**. **Čeština musí být vždy kompletní**: `make test` i CI selžou, když v ní něco chybí. Ostatní jazyky mohou být přeložené jen částečně (nepřeložené texty se ukazují anglicky). Aplikace se řídí jazykem systému (Nastavení systému → Obecné → Jazyk a oblast, případně jazyk jen pro MinorIDE).

## Jak to funguje

```
Sources/**/*.swift   L("Save")                 ← jediný zdroj textů (anglicky)
        │ make l10n
        ▼
Resources/en.lproj/Localizable.strings         ← generuje se, needitovat
Resources/cs.lproj/Localizable.strings         ← překlad (povinný, kompletní)
Resources/<jazyk>.lproj/Localizable.strings    ← další jazyky
```

`make l10n`:
- vygeneruje anglický soubor ze všech `L("…")` v kódu (komentáře se přeskakují);
- do každého jazyka přidá nové texty s anglickou hodnotou a značkou `/* TODO translate */`;
- odstraní texty, které už v kódu nejsou;
- u každého textu uvede v komentáři, ve kterém souboru se používá (kontext pro překladatele).

`make l10n-check` (součást `make test` a CI) selže, když:
- anglický soubor neodpovídá kódu (zapomenuté `make l10n`),
- jazyk nemá některý klíč,
- čeština obsahuje nepřeložený text (`TODO translate`),
- překlad má jiné zástupné znaky než originál (`%d`, `%@`…; pořadí smí změnit přes `%1$@`, `%2$d`).

## Postupy

**Vývojář přidal nebo změnil text v kódu**
1. V kódu vždy `L("Anglický text")`, nikdy text napevno.
2. `make l10n`.
3. V `Resources/cs.lproj/Localizable.strings` přeložit řádky se `TODO translate` a značku smazat.
4. `make test`, commit kódu i obou `.strings` souborů najednou.

**Nový jazyk** (např. němčina, slovenština)
```bash
make l10n-new LANG=de
```
Vytvoří `Resources/de.lproj/Localizable.strings` se všemi texty k překladu. Aplikace jazyk nabídne automaticky (sestavení ho zapíše do `CFBundleLocalizations`). Kódy jazyků podle Apple: `de`, `sk`, `pl`, `fr`, `pt-BR`, `zh-Hans`…

**Překladatel** upravuje jen hodnoty vpravo od `=`:
```
/* MinorIDE/MainMenu.swift */
/* TODO translate */ "Save As…" = "Save As…";      ← před překladem
"Save As…" = "Speichern unter…";                    ← po překladu (značka smazaná)
```
Stačí obyčejný textový editor (soubor je UTF-8). Kontrola: `make l10n-check`.

## Pravidla pro texty
- **Celé věty, žádné skládání** (`L("Saved") + " " + name` je špatně: slovosled se v jazycích liší). Použít formát: `L("Saved “%@”", name)`.
- **Čísla bez gramatického tvaru**: čeština má tvary 1 soubor / 2 soubory / 5 souborů. Dokud nebude `.stringsdict` (množná čísla), formulovat neutrálně („Souborů: %d“, „mezery: %d“).
- **Texty podle Apple**: tři tečky `…` (jeden znak) u příkazů, které otevřou další dotaz („Uložit jako…“); typografické uvozovky „ “ v češtině, “ ” v angličtině; terminologie macOS (Apple má oficiální překlady pojmů: Uložit, Zavřít, Nastavení…, Převést vše do popředí).
- **Položky, které přidává macOS sám** (Diktování, Emotikony, Zavřít vše, Celá obrazovka…), se nepřekládají, přeloží je systém.
