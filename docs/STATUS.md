# Stav práce (pracovní pozice)

Aktualizuje se po každém dokončeném bloku práce. Nová session začíná přečtením tohoto souboru.

**Poslední aktualizace:** 2026-11-15 (1b/3)

## Kde jsme

Hotová je **fáze 0**, **fáze 1a** (TextEngine) a části fáze 1b:

| Oblast | Stav | Kde |
|---|---|---|
| Build bez nástrojů třetích stran (SPM + `tools/bundle.sh`, Makefile) | hotovo | `Package.swift`, `Makefile` |
| Rope (copy-on-write, úpravy na místě, UTF-8/UTF-16/řádky) | hotovo | `Sources/TextEngine/Rope.swift` |
| Multi-selekce (`SelectionSet`, slučování překryvů) a `ChangeSet` (víc změn najednou, mapování pozic) | hotovo | `Sources/TextEngine/Selection.swift` |
| Kotvy (`AnchorSet`: pozice s biasem, posun přes `ChangeSet` včetně undo/redo; `ChangeSet.map` binárním hledáním) | hotovo, `EditorView.anchors` | `Sources/TextEngine/Anchor.swift` |
| Undo/redo (`EditHistory`: kroky z transakcí, inverze `ChangeSet`, obnova selekcí, slučování psaní/mazání: pauza 500 ms, nové slovo, nový řádek, posun kurzoru, uložení) | hotovo | `Sources/TextEngine/History.swift` |
| Editor nad Core Text (ASCII tabulka glyfů, dávkové kreslení, okno cache řádků, zarážky tabulátorů; kurzory ve vlastní `CAShapeLayer` s blikáním přes Core Animation, gutter jako `NSRulerView`, latence přes `displayLink`, základní přístupnost) | `NSTextInputClient` úplný (replacementRange pro podržení klávesy s akcenty, podřetězce, `firstRect`, `characterIndex`; mrtvé klávesy jako překryv u kurzoru), systémové vazby přes `doCommandBySelector` (⌥←/→ po slovech, ⌥⌫, ⌘⌫, ⌃A/⌃E/⌃K/⌃Y/⌃T/⌃L, Home/End jen posun), víc kurzorů, Zpět/Znovu, Vyjmout/Kopírovat (víc výběrů spojí `\n`)/Vybrat vše s validací menu; kreslení výběru, Shift+šipky/Home/End/PgUp/PgDn, klik, dvojklik (slovo), trojklik (řádek), tažení po znacích/slovech/řádcích, Shift+klik, ⌥+klik, ⌥+tažení (sloupec), Esc | `Sources/EditorKit/` |
| Formát souborů (výchozí podle PSR-12/gofmt/Nette, `.editorconfig`, settings.json, konce řádků, kódování, ukládání se zachováním práv a odkazů) | jádro hotové | `Sources/MinorCore/`, `docs/format-settings.md` |
| Standardní menu podle Apple HIG, sheet uložení, Nedávné, otevírání z Finderu | hotovo | `Sources/MinorIDE/MainMenu.swift` |
| Překlady: angličtina (US) z `L("…")`, čeština povinná, množná čísla `LP` + `.stringsdict` | hotovo | `server/cmd/l10n`, `docs/translations.md` |
| Go helper: JSON-RPC, SQLite přes systémovou libsqlite3 | spike | `server/internal/db`, `jsonrpc` |
| PHP lexer + skener deklarací (30 000 souborů za 0,35 s) | spike | `server/internal/php/` |
| CI na GitHub Actions (testy + benchmark s rozpočtem) | testy na CI prochází; benchmark upraven na profil `ci`, ověřit další běh | `.github/workflows/ci.yml` |

Výkon (M2, `make bench`, včetně gutteru a vrstvy kurzorů): psaní znaku p99 0,11 ms, nový řádek 0,31 ms, scroll 0,20 ms, skok 0,43 ms, 1M editací ropu 0,74 s. Podrobnosti: `docs/spike-editor.md`, `docs/spike-phpls.md`.

Repozitář: https://github.com/novami/minor-ide (větev `main`). **Lokálně nepushnuté commity** (uživatel zatím push nechtěl): STATUS.md, oprava benchmarku pro CI a fáze 1a/1b; push jen na jeho pokyn, pak ověřit běh CI.

## Další krok

**Fáze 1a je hotová** (2026-11-15): property-based testy rope, selekcí, kotev a undo/redo (`HistoryTests.interleavedEditsUndoRedoMatchModel`: prokládané psaní, mazání, posuny kurzoru, Zpět/Znovu proti modelu textu a selekcí), 1M editací nad 10 MB za 0,67 s (rozpočet 2 s).

**Fáze 1b, krok 1 hotový** (2026-11-15): vstup z klávesnice (`TextInputTests`: „čšžýáíéůú“, mrtvé klávesy ˇ ´ °, nahrazení rozsahu, systémové vazby), `Rope.byteOffset(ofUTF16:)`, pohyb po slovech v `Sources/TextEngine/Words.swift`.

**Fáze 1b, krok 2 hotový** (2026-11-15): myš (`MouseTests`), `Rope.wordRange(at:)`.

**Fáze 1b, krok 3 hotový** (2026-11-15): kurzory ve vlastní vrstvě (`Carets.swift`: cesta se přestaví jen při posunu kurzorů nebo scrollu mimo pokrytý úsek, blikání podle `NSTextInsertionPointBlinkPeriodOn/Off`, skryté bez fokusu a mimo klíčové okno), gutter jako `NSRulerView` (`GutterView.swift`, překresluje se jen při změně počtu řádků a při scrollu), `LatencyMonitor` (klávesa → commit Core Animation → snímek z `displayLink`; v benchmarku a v aplikaci s `MINORIDE_LATENCY=1`), přístupnost (`Accessibility.swift`: role textArea, řádky/rozsahy v UTF-16, notifikace jen po prvním dotazu asistenční aplikace). Testy `LayerTests`.

**Další: „Hotovo když“ fáze 1b** – s rozsvíceným a odemčeným displejem spustit `make bench` (sekce „key to frame“ se při zamčené obrazovce přeskočí, zatím **neověřeno**), ruční test „čšžýáíéůú“ na české klávesnici v aplikaci (`make run`), ověřit VoiceOverem čtení řádku (⌘F5, šipky nahoru/dolů). Pak fáze 1c.

Známé mezery po kroku 1b/3: rozpočet „key to frame“ je zvolen jako p99 ≤ 8 ms + 1 snímek displeje (max 16 ms + snímek), protože plánovaných „< 8 ms“ nejde na 60Hz displeji fyzicky splnit až do snímku – k potvrzení s uživatelem; „key to commit“ hlídá 8 ms. Gutter má pevnou šířku na 7 číslic a při každém scrollu se kreslí celý (≈ 0,1 ms). Barva kurzoru se nepřepočítá při změně systémové barvy zvýraznění, dokud se kurzor nepohne. `accessibilityValue` vrací celý text (u 10 MB pomalé, jen když se VoiceOver zeptá). Benchmark kreslí synchronně přes `layer.displayIfNeeded()`; `CATransaction.flush()` by čekal na render server (≈ 3,5 ms) a měří se zvlášť přes latenci.

Známé mezery po kroku 1b/2: sloupcový výběr dává na krátkých řádcích prázdný kurzor na konci řádku (nevynechává je); sloupec počítá s x pozicí, ne s vizuálním sloupcem (u tabulátorů a širokých znaků se posune); autoscroll při tažení jen podle `autoscroll(with:)`, bez opakování při stojící myši.

Známé mezery po kroku 1b/1: marked text se kreslí jen u primárního kurzoru jako překryv (dlouhá kompozice IME zakryje text za kurzorem, neodsune ho); s víc kurzory ⌃Y vloží celý kill buffer ke každému; ruční ověření na skutečné české klávesnici a s IME (japonština) v běžící aplikaci zatím neproběhlo.

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
