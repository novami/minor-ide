# Stav práce (pracovní pozice)

Aktualizuje se po každém dokončeném bloku práce. Nová session začíná přečtením tohoto souboru.

**Poslední aktualizace:** 2026-11-15 (1c jazykové příkazy)

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

**Benchmark s displejem ověřen** (2026-11-15, 60 Hz): klávesa→commit p99 0,5 ms, klávesa→snímek p99 ≈ 32 ms = dva snímky (čekání na vsync + složení snímku render serverem; klávesy jdou hned po vsync, tedy nejhorší fáze). Rozpočet: klávesa→commit 8 ms/max 16 ms (plán), klávesa→snímek p99 ≤ 2 snímky + 1 ms (editor nezmešká snímek).

**Výklad rozpočtu latence potvrzen uživatelem** (2026-11-15).

**Odloženo (připomenout uživateli na začátku další session, od 2026-11-16):** ruční část „Hotovo když“ 1b – v aplikaci (`make run`) napsat „čšžýáíéůú“ na české klávesnici (i přes mrtvé klávesy ˇ a ´) a zkusit VoiceOver (⌘F5, šipky nahoru/dolů čtou řádek). Fázi 1b to neblokuje.

**Fáze 1c, krok 1 hotový** (2026-11-15): řádkové příkazy v `Sources/EditorKit/LineCommands.swift` — Duplikovat řádek ⇧⌘D, Přesunout řádek ⌥⌘↑/↓, Vybrat další výskyt ⌃G, všechny výskyty ⌃⌘G, Převést odsazení (Formát › Odsazení); hledání v ropu po blocích `Sources/TextEngine/Search.swift`. Checklist `docs/editor-behaviors.md`. Testy `LineCommandTests`, `RopeSearchTests`.

**Rozhodnutí uživatele:** komentáře, párování závorek, chytré odsazení a folding podle závorek až po 1d nad lexerem; hledání vlastní lištou (zapsáno v plánu u 1c).

**Fáze 1c, krok 2 hotový** (2026-11-15): Hledat/nahradit v souboru. `Sources/TextEngine/Find.swift` (`FindQuery`: regex přes `NSRegularExpression`, velikost písmen, celá slova, šablony $1 \n \t, zachování velikosti; `ChangeSet.mapUntouched` posune zvýraznění přes editace), `Sources/EditorKit/FindController.swift` (hledání mimo hlavní vlákno nad snímkem ropu, generace zahodí staré výsledky, Nahradit a najít, Nahradit vše jako jeden krok Zpět), `Sources/MinorIDE/FindBar.swift` (lišta nad editorem: pole, počet „3 z 12“, Aa / W / .* / AB, ‹ ›, Hotovo; druhý řádek Nahradit, Vše), akce v `DocumentWindow` (delegát okna je v responder chainu editoru i lišty), menu Úpravy › Najít: ⌘F, ⌥⌘F, ⌘G, ⇧⌘G, ⌘E, ⇧⌘E, ⌘J; sdílená schránka hledání macOS. Testy `FindTests`, `FindControllerTests`. `make bench` BUDGET OK (psaní p99 0,10 ms). `MINORIDE_FIND=<dotaz>` se `--snapshot` otevře lištu (ovládací prvky AppKit na macOS 27 kreslí přes hostované vrstvy, `cacheDisplay` je nevykreslí; rozložení ověřeno výpisem rámců).

**Fáze 1c, krok 3 hotový** (2026-11-15): folding podle odsazení. `Sources/TextEngine/Folding.swift` (oblasti, hlavičky, všechny oblasti jedním průchodem, odsazení viditelných řádků jedním čtením), `Sources/TextEngine/DisplayMap.swift` (řádek ↔ zobrazený řádek binárním hledáním; v 1f se rozšíří o zalamování), `Sources/EditorKit/Folding.swift` (příkazy, šipky v gutteru, „…“ za řádkem). Editor kreslí, posouvá, myš a kurzory přes `y(ofLine:)` / `line(atY:)`. Sbalení jsou bajtové rozsahy, jdou s editacemi (`mapUntouched(closedEnd:)`), editace uvnitř nebo výběr uvnitř je rozbalí. Menu Zobrazení › Sbalování kódu. Testy `FoldRegionTests`, `FoldingTests`. `make bench` BUDGET OK (nový řádek p99 0,31 ms, scroll 0,21 ms; šipky v gutteru nejdřív přidaly 0,15 ms, vyřešeno jedním čtením odsazení).

**Fáze 1c je hotová** kromě částí odložených za 1d (komentáře, párování a obalování závorkami, chytré odsazení, folding podle závorek).

**Fáze 1d, krok 1 hotový** (2026-11-15): nový modul `Sources/Highlight/` (bez AppKitu): `Token.swift` (druhy tokenů, `LexState` s režimem, zásobníkem a textem, protokol `Lexer` nad `ArraySlice<UInt8>`, `WordSet` bez alokací, `LineScanner`), `SyntaxHighlighter.swift` (stav na začátku řádku v `GapArray`, přelexování od editace do shody stavů, limit 2000 řádků, líné dopočítání, dolexování na pozadí s generací), `Theme.swift` (světlé a tmavé téma jako JSON), `Languages.swift` (lexer podle přípony), lexery Go a JSON (s komentáři). Editor barví po druzích tokenů jedním voláním na barvu (`EditorKit/SyntaxDrawing.swift`), fallback řádky (emoji) přes obarvený `CTLine`. Golden testy `Tests/HighlightTests/Golden/` (`MINORIDE_UPDATE_GOLDEN=1 make test` přepíše očekávané výstupy), `SyntaxHighlighterTests` (náhodné editace proti lexování od začátku). Bench: psaní v Go p99 0,19 ms, skok p99 0,79 ms, dolexování 10 MB na pozadí 97 ms, celý lex 129 ms; BUDGET OK.

**Fáze 1d, krok 2 hotový** (2026-11-15): lexery `PHPLexer` (HTML kolem s tagy, atributy, entitami a komentáři; `<?php`/`<?=` i uvnitř hodnot atributů přes zásobník režimů; řetězce přes víc řádků, interpolace `$var`, `{$…}`, `$a->b`; heredoc/nowdoc s ukončovačem ve stavu; doc komentáře s `@tagy`; atributy `#[…]`; jména s namespace; PascalCase = typ, VELKÁ = konstanta), `SQLLexer` (MySQL/PostgreSQL, '' a \' v řetězcích, placeholdery ?, :name, $1), `NEONLexer` (klíče, @služby, %parametry%, entity, ''' víceřádkové řetězce). `WordSet` až 24 bajtů. Golden vzorky `sample.php`, `schema.sql`, `config.neon`.

**Fáze 1d, krok 3 hotový — fáze 1d je hotová** (2026-11-15): `LatteLexer` (HTML, `{tagy}` s výrazy a `|filtry`, `{* komentáře *}` přes řádky, `n:atributy` s výrazem v hodnotě, tagy i v hodnotách atributů, HTML komentářích a ve `<script>`/`<style>`; obsah skriptů a stylů zatím prostý text — JS/CSS lexery jsou v 1f). Golden `layout.latte`. Rozpočet přelexování: psaní v Go p99 0,19 ms včetně kreslení (bench `type char go`).

**Jazykové příkazy z 1c hotové** (2026-11-15): `Sources/Highlight/Languages.swift` (`SyntaxLanguage`: lexer, komentáře, závorky, uvozovky, odsazení za `:`; komentář podle stavu lexeru — HTML části PHP), `Sources/EditorKit/LanguageCommands.swift`: ⌘/ (Úpravy › Zakomentovat výběr), párování a obalování, přepisování zavíracích znaků, Backspace v prázdném páru, chytrý Enter a zavírací závorka na prázdném řádku. Nic z toho neplatí uvnitř řetězců a komentářů (podle tokenů). Testy `LanguageCommandTests`. Bench BUDGET OK. Folding podle závorek se nedělal: u formátovaného kódu dává totéž co folding podle odsazení (otevřené).

**Fáze 1c a 1d jsou hotové.** Z 1e předběžně hotový zjednodušený režim: soubor nad 5 MB nebo s řádkem nad 10 000 bajtů se otevře bez zvýraznění (`TextFile.needsSimplifiedMode`); chybí ještě označení v okně a ruční zapnutí zvýraznění.

**Další: fáze 1e (projekt a pracovní prostředí)** podle `docs/PLAN.md` — před začátkem probrat s uživatelem otázky v sekci „Otázky pro uživatele“ níže.

Známé mezery po jazykových příkazech: zavírací znak se přepíše vždy, když je hned za kurzorem (i když ho editor sám nevložil); ⌘/ na české klávesnici vyžaduje Shift (řeší keymapa v 1e); u neukončeného řetězce na konci řádku se Enter za `{` uvnitř něj odsadí; párování nejde vypnout (nastavení v 1e).

Známé mezery po kroku 1d/1: téma se nedá změnit v nastavení (jen vestavěné světlé/tmavé); tokeny viditelných řádků se lexují při každém kreslení (bez cache, v rozpočtu); po editaci s limitem 2000 řádků se zbytek dopočítá na pozadí až po 300 ms; Uložit jako s jinou příponou nezmění jazyk.

Známé mezery po kroku 1c/3: Enter na konci sbalené hlavičky posune sbalení pod nový řádek (hlavičkou se stane nový řádek); přesun a duplikace řádku se sbalenou hlavičkou berou jen hlavičku (sbalení se rozbalí); šipky v gutteru se kreslí u všech řádků, které jdou sbalit (ne až při najetí myší); sbalení se neukládají; ruční kontrola kliknutí zbývá.

Známé mezery po kroku 1c/2: lišta hledání nebyla vyzkoušena ručně (Return/Shift+Return/Esc, fokus, vzhled v tmavém režimu) — obrazovka byla zamčená; hledání pustí regex nad celým textem (10 MB ≈ desítky ms mimo hlavní vlákno, bez limitu počtu shod); stav „3 z 12“ se neaktualizuje při ručním posunu kurzoru; regex v jednom nahrazení vidí jen řádky shody (look-behind přes začátek řádku nefunguje); vlastní lišta, ne `NSTextFinder` (rozhodnutí uživatele).

Poučení: výjimka Objective-C v `init` okna (omezení mezi pohledy bez společného předka) se nezobrazí, AppKit ji spolkne a otevření okna skončí potichu — benchmark pak „visí“.

Známé mezery po kroku 1c/1: kotvy na řádku prohozeném při přesunu se sbalí (kotvy v přesouvaném bloku jdou s ním); ⌃G hledá jen s rozlišením velikosti písmen; ⌃⌘G nad 10 MB s častým slovem vytvoří desítky tisíc výběrů bez limitu; keymapa (`docs/keymap.md`) až v 1e.

Známé mezery po kroku 1b/3: výklad rozpočtu latence z plánu („< 8 ms do vykresleného snímku“) je upraven (viz výše) (potvrzeno); na zamčené obrazovce se sekce latence přeskočí. Gutter má pevnou šířku na 7 číslic a při každém scrollu se kreslí celý (≈ 0,1 ms). Barva kurzoru se nepřepočítá při změně systémové barvy zvýraznění, dokud se kurzor nepohne. `accessibilityValue` vrací celý text (u 10 MB pomalé, jen když se VoiceOver zeptá). Benchmark kreslí synchronně přes `layer.displayIfNeeded()`; `CATransaction.flush()` by čekal na render server (≈ 3,5 ms) a měří se zvlášť přes latenci.

Známé mezery po kroku 1b/2: sloupcový výběr dává na krátkých řádcích prázdný kurzor na konci řádku (nevynechává je); sloupec počítá s x pozicí, ne s vizuálním sloupcem (u tabulátorů a širokých znaků se posune); autoscroll při tažení jen podle `autoscroll(with:)`, bez opakování při stojící myši.

Známé mezery po kroku 1b/1: marked text se kreslí jen u primárního kurzoru jako překryv (dlouhá kompozice IME zakryje text za kurzorem, neodsune ho); s víc kurzory ⌃Y vloží celý kill buffer ke každému; ruční ověření na skutečné české klávesnici a s IME (japonština) v běžící aplikaci zatím neproběhlo.

Známé mezery po kroku 3: kotva v smazaném textu se sbalí na místo smazání a Zpět ji nevrátí (breakpoint na smazaném řádku po Zpět zůstane o řádek výš/níž); kotvy jsou jen body, rozsah (diagnostika) = dvě kotvy; `anchors(in:)` prochází všechny kotvy (O(n)), pro tisíce kotev v gutteru případně seřazené pole.

Známé mezery po kroku 2: Zpět až na uložený stav nesmaže příznak „upraveno“; historie nemá limit velikosti; Kopírovat bez výběru nic nedělá (kopie řádku až v 1c).

Známé mezery po kroku 1: Tab s víceřádkovým výběrem výběr nahradí (odsazení bloku patří do 1c), vložení více řádků do stejného počtu kurzorů nerozděluje text, dvojklik/trojklik a ⌥+tažení jsou v 1b.

Pak zbytek 1c (hledání, folding), 1d (lexery a zvýraznění) a po ní jazykové příkazy z 1c.

**Revize plánu 2026-11-14** (pořadí fází se změnilo, další krok ne): nová fáze 2b (otevření souboru, hledání, Git gutter, terminál) před LSP, debugger Go a testy v MVP (7b; PHP přes Tracy, Xdebug až po MVP), žádná vazba na konkurenční IDE (stuby PHP z oficiálních zdrojů PHP, D25), Git rozšířen o konflikty, externí LSP servery (D23), PHP až po aktuální verzi. Opravy, které se týkají už hotového kódu nebo nejbližší práce:
- zkratky: písmena podle znaku, keyCode jen pro interpunkci (1e); ⌘E zůstává systémové;
- 1b: klávesy mimo keymapu přes `doCommandBySelector`;
- důvěra projektu mimo projekt (`trusted.json`), `.minoride/local.json` se v Omezeném režimu nečte;
- prostředí ze shellu přes `-l -i -c` (D22).

## Otázky pro uživatele (připravené 2026-11-15, před fází 1e)
1. **Push**: lokálně je řada nepushnutých commitů (1a–1d). Pushnout a ověřit CI (benchmark má nové sekce `type char go`, `scroll jump go`)?
2. **Taby v projektovém okně (1e)**: (a, doporučeno) vlastní lišta tabů v editorové oblasti (umožní split vertikálně i horizontálně a „Znovu otevřít zavřený tab“), nativní tabování oken vypnuté; (b) nativní taby oken macOS (HIG, ale split a přesuny mezi skupinami jsou omezené).
3. **Zkratky zvolené bez keymapy**: Duplikovat řádek ⇧⌘D, Přesunout řádek ⌥⌘↑/↓, Sbalit/Rozbalit ⌥⌘←/→ (vše ⌥⇧⌘←/→), Zakomentovat ⌘/, výskyty ⌃G / ⌃⌘G. Ponechat do `docs/keymap.md`?
4. **Barvy témat**: vestavěné světlé/tmavé jsou vlastní paleta. Mají být v 1e uživatelská témata (JSON v `~/Library/Application Support/MinorIDE/themes/`) a výběr v Nastavení?
5. **Ruční kontroly** (čekají na uživatele): čeština na skutečné klávesnici a mrtvé klávesy, VoiceOver, lišta hledání (Return/Shift+Return/Esc, tmavý režim), klik na šipky foldingu a „…“, barvy v tmavém i světlém režimu.

## Otevřené věci mimo kód
- **Apple Developer účet** (potřeba pro fázi 2: podepsané aktualizace).
- **CI**: první běh (macOS 26.7, Xcode 26.6) — testy prošly, benchmark selhal na jednorázových špičkách virtuálního stroje (první stisk 163 ms, otevření za studena 440 ms; p99 byly pod 8 ms). Opraveno zahřátím a profilem `MINORIDE_BENCH_PROFILE=ci` (hlídá p99 ≤ 8 ms a rope ≤ 4 s). Po pushi ověřit, že běh projde.

## Poznámky k prostředí
- Mac má jen **Command Line Tools** (bez Xcode): testy vždy přes `make test` (obchází chybu SwiftPM se Swift Testing).
- Go 1.27.4 a Composer 2.11 nainstalované přes Homebrew.
- Push na GitHub: `git push` (token v `GH_TOKEN` má oprávnění `workflow`); pokud git nezná přihlášení, `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`.
- Testovací PHP projekt pro skener: `composer create-project nette/web-project <složka> --no-interaction --no-scripts`, pak `server/bin/minoride-server phpscan <složka>`.
- Ladicí přepínače aplikace: `--bench`, `--snapshot <png> [soubor]`, `--dump-menu`, `--l10n-sample` (s `-AppleLanguages "(cs)"`).
