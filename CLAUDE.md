# MinorIDE

Nativní IDE pro PHP a Go na macOS (Apple Silicon), celé ve Swiftu. Dokumenty (anglicky): `docs/PRD.md` (rozsah), `docs/ARCHITECTURE.md`, `docs/DECISIONS.md` (ADR), `docs/ROADMAP.md` (fáze), `docs/SECURITY.md`, `docs/PERFORMANCE.md`, `docs/LOCALIZATION.md`, `docs/UI-GUIDELINES.md`, `docs/DEPENDENCIES.md`.

**Pracovní pozice: `docs/STATUS.md`.** Na začátku session ho přečti a pokračuj „Next step“. Po každém dokončeném bloku práce ho aktualizuj (co je hotové, další krok, otevřené věci), commitni a řekni uživateli, že může vyčistit kontext.

## Příkazy
- `make test` – Swift testy (+ zatím Go testy dočasného `server/`); vždy přes make: SwiftPM s Command Line Tools potřebuje native build system a cesty k Swift Testing
- `make bench` – výkonový benchmark editoru (release)
- `make bundle` / `make run` – sestaví a spustí `build/MinorIDE.app`
- `make server` – dočasný Go helper (hledání) do jeho portu do Swiftu ve fázi R3
- `make l10n` – po změně `Resources/Localization/en-US.json` přegeneruje `Strings.swift` (`docs/LOCALIZATION.md`); `make l10n-check` validuje (součást `make test`)

## Pravidla
- Pracuj po úkolech v pořadí fází z `docs/ROADMAP.md`. Úkol končí splněním „Done when“, testem hlavní cesty a commitem.
- Commity malé, jen vlastní soubory (`git commit -- <soubory>`), bez AI podpisů. Nikdy `git push` bez vyžádání.
- **Jen Swift** (ADR-1). Nový Go kód nepsat; `server/` se portuje do Swiftu a pak smaže.
- **Žádná nová závislost bez souhlasu uživatele.** Povolené: SwiftTerm, oficiální stuby PHP ze zdrojů PHP a PECL rozšíření (data). Systémové frameworky macOS jsou volné.
- **PHP inteligence přímo v aplikaci, bez LSP** (ADR-4). LSP jen pro gopls (ADR-5). PHP nástroje (PHPStan, Psalm, fixery, Composer, testy) jen přes CLI.
- **Žádná vazba na konkurenční IDE**: nejmenovat je v UI, kódu, dokumentaci ani commitech a nepodporovat jejich vlastní formáty souborů ani jejich data.
- Na hlavním vlákně jen UI. Změna v editační cestě musí projít `make bench` v rozpočtu z `docs/PERFORMANCE.md`.
- Moduly pod UI (`TextEngine`, `Highlight`, `LanguageKit`, `PHPKit`, `LSPKit`, `ProjectKit`, `ToolKit`, `MinorCore`, `Localization` …) nesmí importovat AppKit.
- PHP: každá nová schopnost začíná markerovým testem; každá opravená chyba parseru dostane fixture. Parser nikdy nesmí spadnout (žádné `!`, kontrolované indexy, časový limit).
- **UI podle Apple HIG** (`docs/UI-GUIDELINES.md`): standardní lišta menu a zkratky, sheety místo modálních dialogů, okno Nastavení (⌘,), systémové barvy a tmavý režim. Pracovní okno v AppKitu, SwiftUI pro nastavení, Dashboard, formuláře a panely. Každý text v UI lokalizovaný přes `Strings.<klíč>` (klíč v `en-US.json` i `cs-CZ.json`, `make l10n`, vše ve stejném commitu); čeština musí být vždy kompletní (kontrola je součást `make test`).
- **Kód, komentáře a dokumentace anglicky** (jednoduchá US angličtina); čeština jen v překladech. Tento soubor a odpovědi uživateli česky.
- **Bezpečnost** (`docs/SECURITY.md`): hesla jen v Klíčence; nikdy v argumentech procesů, proměnných prostředí, logu ani souborech. Procesy spouštět s polem argumentů, nikdy přes shell se složeným řetězcem. Neznámý projekt = Omezený režim (nespouštět jeho nástroje ani příkazy z jeho nastavení, ani Git, gopls, `go` s cizím toolchainem, Composer, Docker a debugger; důvěra se ukládá mimo projekt). SSH jen se ověřeným klíčem serveru. Žádné síťové porty; výjimky: Delve na `127.0.0.1` během ladění, askpass přes unixový socket.
- Když se rozhodnutí z ADR ukáže jako špatné, zastav a popiš varianty. Technologii neměň sám.
- Swift: taby, Swift 6 strict concurrency.
