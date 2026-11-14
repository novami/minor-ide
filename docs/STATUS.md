# Stav práce (pracovní pozice)

Aktualizuje se po každém dokončeném bloku práce. Nová session začíná přečtením tohoto souboru.

**Poslední aktualizace:** 2026-11-15

## Kde jsme

Hotová je **fáze 0**, **fáze 1a** (TextEngine) a části fáze 1b:

| Oblast | Stav | Kde |
|---|---|---|
| Build bez nástrojů třetích stran (SPM + `tools/bundle.sh`, Makefile) | hotovo | `Package.swift`, `Makefile` |
| Rope (copy-on-write, úpravy na místě, UTF-8/UTF-16/řádky) | hotovo | `Sources/TextEngine/Rope.swift` |
| Multi-selekce (`SelectionSet`, slučování překryvů) a `ChangeSet` (víc změn najednou, mapování pozic) | hotovo | `Sources/TextEngine/Selection.swift` |
| Kotvy (`AnchorSet`: pozice s biasem, posun přes `ChangeSet` včetně undo/redo; `ChangeSet.map` binárním hledáním) | hotovo, `EditorView.anchors` | `Sources/TextEngine/Anchor.swift` |
| Undo/redo (`EditHistory`: kroky z transakcí, inverze `ChangeSet`, obnova selekcí, slučování psaní/mazání: pauza 500 ms, nové slovo, nový řádek, posun kurzoru, uložení) | hotovo | `Sources/TextEngine/History.swift` |
| Editor nad Core Text (ASCII tabulka glyfů, dávkové kreslení, okno cache řádků, zarážky tabulátorů) | víc kurzorů, Zpět/Znovu, Vyjmout/Kopírovat (víc výběrů spojí `\n`)/Vybrat vše s validací menu; kreslení výběru, Shift+šipky/Home/End/PgUp/PgDn, klik, tažení, Shift+klik, ⌥+klik, Esc | `Sources/EditorKit/` |
| Formát souborů (výchozí podle PSR-12/gofmt/Nette, `.editorconfig`, settings.json, konce řádků, kódování, ukládání se zachováním práv a odkazů) | jádro hotové | `Sources/MinorCore/`, `docs/format-settings.md` |
| Standardní menu podle Apple HIG, sheet uložení, Nedávné, otevírání z Finderu | hotovo | `Sources/MinorIDE/MainMenu.swift` |
| Překlady: angličtina (US) z `L("…")`, čeština povinná, množná čísla `LP` + `.stringsdict` | hotovo | `server/cmd/l10n`, `docs/translations.md` |
| Go helper: JSON-RPC, SQLite přes systémovou libsqlite3 | spike | `server/internal/db`, `jsonrpc` |
| PHP lexer + skener deklarací (30 000 souborů za 0,35 s) | spike | `server/internal/php/` |
| CI na GitHub Actions (testy + benchmark s rozpočtem) | testy na CI prochází; benchmark upraven na profil `ci`, ověřit další běh | `.github/workflows/ci.yml` |

Výkon (M2, `make bench`): psaní znaku 0,05 ms, skok na jiné místo 0,30 ms, 1M editací ropu 0,66 s. Podrobnosti: `docs/spike-editor.md`, `docs/spike-phpls.md`.

Repozitář: https://github.com/novami/minor-ide (větev `main`). **Lokálně nepushnuté commity** (uživatel zatím push nechtěl): STATUS.md a oprava benchmarku pro CI; push jen na jeho pokyn, pak ověřit běh CI.

## Další krok

**Fáze 1a je hotová** (2026-11-15): property-based testy rope, selekcí, kotev a undo/redo (`HistoryTests.interleavedEditsUndoRedoMatchModel`: prokládané psaní, mazání, posuny kurzoru, Zpět/Znovu proti modelu textu a selekcí), 1M editací nad 10 MB za 0,67 s (rozpočet 2 s).

**Další: fáze 1b – vykreslování a vstup** (`docs/PLAN.md`): `NSTextInputClient` (marked text, česká diakritika přes mrtvé klávesy, IME), klávesy mimo keymapu přes `interpretKeyEvents`/`doCommandBySelector`, dvojklik/trojklik, ⌥+tažení (sloupcový výběr), kurzory ve vlastní vrstvě, gutter, měření latence přes `NSView.displayLink`. Nejdřív zjistit, co z 1b už `EditorKit` má.

Známé mezery po kroku 3: kotva v smazaném textu se sbalí na místo smazání a Zpět ji nevrátí (breakpoint na smazaném řádku po Zpět zůstane o řádek výš/níž); kotvy jsou jen body, rozsah (diagnostika) = dvě kotvy; `anchors(in:)` prochází všechny kotvy (O(n)), pro tisíce kotev v gutteru případně seřazené pole.

Známé mezery po kroku 2: Zpět až na uložený stav nesmaže příznak „upraveno“; historie nemá limit velikosti; Kopírovat bez výběru nic nedělá (kopie řádku až v 1c).

Známé mezery po kroku 1: Tab s víceřádkovým výběrem výběr nahradí (odsazení bloku patří do 1c), vložení více řádků do stejného počtu kurzorů nerozděluje text, dvojklik/trojklik a ⌥+tažení jsou v 1b.

Pak 1c (příkazy, hledání), 1d (lexery a zvýraznění).

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
