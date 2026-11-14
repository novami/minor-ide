# Překlady

Výchozí jazyk aplikace je **angličtina (US)**. **Čeština musí být vždy kompletní**: `make test` i CI selžou, když v ní něco chybí. Ostatní jazyky mohou být přeložené jen částečně (nepřeložené texty se ukazují anglicky). Aplikace se řídí jazykem systému (Nastavení systému → Obecné → Jazyk a oblast, případně jazyk jen pro MinorIDE).

## Jak to funguje

```
Sources/**/*.swift   L("Save")                 ← jediný zdroj textů (anglicky)
        │ make l10n
        ▼
Resources/en.lproj/Localizable.strings         ← generuje se, needitovat
Resources/en.lproj/Localizable.stringsdict     ← generuje se (množná čísla), needitovat
Resources/cs.lproj/Localizable.strings         ← překlad (povinný, kompletní)
Resources/cs.lproj/Localizable.stringsdict     ← generuje se z tvarů v .strings, needitovat
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

## Množná čísla

Texty s počtem se skloňují podle pravidel jazyka (Unicode CLDR, vyhodnocuje je macOS):

| Jazyk | Povinné tvary | Příklad |
|---|---|---|
| angličtina | `one`, `other` | 1 space · 0, 2, 5 spaces |
| čeština, slovenština | `one`, `few`, `other` | 1 mezera · 2–4 mezery · 0, 5–20, 21, 22, 101 mezer |
| polština, ruština, ukrajinština | `one`, `few`, `many`, `other` | |
| japonština, korejština, čínština | `other` | |
| ostatní | `one`, `other` | |

V kódu:
```swift
LP("%d spaces", one: "%d space", count)   // anglický plurál je klíč, singulár v `one:`
```
V překladu má každý tvar vlastní řádek s příponou `|tvar`:
```
"%d spaces|one" = "%d mezera";
"%d spaces|few" = "%d mezery";
"%d spaces|other" = "%d mezer";
```
`make l10n` doplní chybějící tvary podle jazyka (se `TODO translate`) a vygeneruje `Localizable.stringsdict`, který macOS používá. Volitelné tvary (např. české `many` pro desetinná čísla) lze přidat ručně a zůstanou zachované. Tvar smí počet vynechat („jedna mezera“), ale nesmí přidat ani změnit jiné zástupné znaky. Počet je vždy první a jediný argument `LP`.

Ověření v sestavené aplikaci:
```bash
build/MinorIDE.app/Contents/MacOS/MinorIDE --l10n-sample -AppleLanguages "(cs)"
```

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
- **Počty vždy přes `LP`**, nikdy `L("%d files")`: jinak vznikne „1 files“ nebo „5 soubory“.
- **Texty podle Apple**: tři tečky `…` (jeden znak) u příkazů, které otevřou další dotaz („Uložit jako…“); typografické uvozovky „ “ v češtině, “ ” v angličtině; terminologie macOS (Apple má oficiální překlady pojmů: Uložit, Zavřít, Nastavení…, Převést vše do popředí).
- **Položky, které přidává macOS sám** (Diktování, Emotikony, Zavřít vše, Celá obrazovka…), se nepřekládají, přeloží je systém.
