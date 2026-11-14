# Stav práce (pracovní pozice)

Aktualizuje se po každém dokončeném bloku práce. Nová session začíná přečtením tohoto souboru.

**Poslední aktualizace:** 2026-11-14

## Kde jsme

Hotová je **fáze 0** a části fáze 1:

| Oblast | Stav | Kde |
|---|---|---|
| Build bez nástrojů třetích stran (SPM + `tools/bundle.sh`, Makefile) | hotovo | `Package.swift`, `Makefile` |
| Rope (copy-on-write, úpravy na místě, UTF-8/UTF-16/řádky) | hotovo, chybí selekce, undo, kotvy | `Sources/TextEngine/Rope.swift` |
| Editor nad Core Text (ASCII tabulka glyfů, dávkové kreslení, okno cache řádků, zarážky tabulátorů) | spike, jeden kurzor | `Sources/EditorKit/` |
| Formát souborů (výchozí podle PSR-12/gofmt/Nette, `.editorconfig`, settings.json, konce řádků, kódování, ukládání se zachováním práv a odkazů) | jádro hotové | `Sources/MinorCore/`, `docs/format-settings.md` |
| Standardní menu podle Apple HIG, sheet uložení, Nedávné, otevírání z Finderu | hotovo | `Sources/MinorIDE/MainMenu.swift` |
| Překlady: angličtina (US) z `L("…")`, čeština povinná, množná čísla `LP` + `.stringsdict` | hotovo | `server/cmd/l10n`, `docs/translations.md` |
| Go helper: JSON-RPC, SQLite přes systémovou libsqlite3 | spike | `server/internal/db`, `jsonrpc` |
| PHP lexer + skener deklarací (30 000 souborů za 0,35 s) | spike | `server/internal/php/` |
| CI na GitHub Actions (testy + benchmark s rozpočtem) | testy na CI prochází; benchmark upraven na profil `ci`, ověřit další běh | `.github/workflows/ci.yml` |

Výkon (M2, `make bench`): psaní znaku 0,05 ms, skok na jiné místo 0,30 ms, 1M editací ropu 0,66 s. Podrobnosti: `docs/spike-editor.md`, `docs/spike-phpls.md`.

Repozitář: https://github.com/novami/minor-ide (větev `main`). **Lokálně nepushnuté commity** (uživatel zatím push nechtěl): STATUS.md a oprava benchmarku pro CI; push jen na jeho pokyn, pak ověřit běh CI.

## Další krok

**Fáze 1a: dokončit TextEngine** (`docs/PLAN.md`, fáze 1):
1. Multi-selekce v `TextEngine` (seřazené rozsahy, slučování překryvů), napojení do `EditorView` (kreslení výběru, Shift+šipky, myš).
2. Transakce editací a undo/redo se slučováním psaní a obnovou selekcí; menu Zpět/Znovu, Kopírovat/Vyjmout/Vybrat vše.
3. Kotvy (pozice, které přežijí editace).
4. Property-based testy selekcí a undo.

Pak 1b (vstup, myš, displayLink), 1c (příkazy, hledání), 1d (lexery a zvýraznění).

**Revize plánu 2026-11-14** (pořadí fází se změnilo, další krok ne): nová fáze 2b (otevření souboru, hledání, Git gutter, terminál) před LSP, debugger Go a testy v MVP (7b; PHP přes Tracy, Xdebug až po MVP), žádná vazba na konkurenční IDE (stuby PHP z oficiálních zdrojů PHP, D25), Git rozšířen o konflikty, externí LSP servery (D23), PHP až po aktuální verzi. Opravy, které se týkají už hotového kódu nebo nejbližší práce:
- zkratky: písmena podle znaku, keyCode jen pro interpunkci (1e); ⌘E zůstává systémové;
- 1b: klávesy mimo keymapu přes `doCommandBySelector`;
- důvěra projektu mimo projekt (`trusted.json`), `.minoride/local.json` se v Omezeném režimu nečte;
- prostředí ze shellu přes `-l -i -c` (D22).

## Otevřené věci mimo kód
- **Apple Developer účet** (potřeba pro fázi 2: podepsané aktualizace).
- **CI**: první běh (macOS 26.7, Xcode 26.6) — testy prošly, benchmark selhal na jednorázových špičkách virtuálního stroje (první stisk 163 ms, otevření za studena 440 ms; p99 byly pod 8 ms). Opraveno zahřátím a profilem `MINORIDE_BENCH_PROFILE=ci` (hlídá p99 ≤ 8 ms a rope ≤ 4 s). Po pushi ověřit, že běh projde.

## Poznámky k prostředí
- Mac má jen **Command Line Tools** (bez Xcode): testy vždy přes `make test` (obchází chybu SwiftPM se Swift Testing).
- Go 1.27.4 a Composer 2.11 nainstalované přes Homebrew.
- Push na GitHub: `git push` (token v `GH_TOKEN` má oprávnění `workflow`); pokud git nezná přihlášení, `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`.
- Testovací PHP projekt pro skener: `composer create-project nette/web-project <složka> --no-interaction --no-scripts`, pak `server/bin/minoride-server phpscan <složka>`.
- Ladicí přepínače aplikace: `--bench`, `--snapshot <png> [soubor]`, `--dump-menu`, `--l10n-sample` (s `-AppleLanguages "(cs)"`).
