# Implementační plán: MinorIDE, nativní IDE pro Go a PHP (macOS, Apple Silicon)

- Název: **MinorIDE** (`MinorIDE.app`, bundle id `cz.novami.minoride`), repozitář `github.com/novami/minor-ide`, licence **MIT**.
- Cílový stroj: M2, 16 GB RAM, macOS 14+.
- Implementuje: Sonnet, po úkolech v pořadí níže. Každý úkol má **Hotovo když**.
- Analýza konkurence: [ANALYZA.md](ANALYZA.md). Volba závislostí: [ZAVISLOSTI.md](ZAVISLOSTI.md).

**Filozofie: minimum knihoven třetích stran.** Vlastní je editor, zvýraznění, všechny parsery, LSP, updater, hledání i build. Knihovny zůstávají jen tam, kde by vlastní implementace stála měsíce bez přínosu: SwiftTerm, ovladače MySQL a PostgreSQL a data phpstorm-stubs.

---

## 0. Rozhodnutí (potvrzená)

| # | Rozhodnutí | Volba |
|---|---|---|
| D1 | UI | Swift 6 + AppKit; SwiftUI jen pro nastavení a dialogy |
| D2 | Editor | **vlastní**: rope + vykreslování přes Core Text, 0 závislostí |
| D3 | Zvýraznění | **vlastní inkrementální lexery** (stav na začátku řádku) ve Swiftu |
| D4 | Go inteligence | gopls přes LSP, `staticcheck` zapnutý |
| D5 | PHP inteligence | **vlastní jazykový server v Go s vlastním parserem**, PHP **7.2–8.4**, doplněný o PHPStan |
| D6 | Nette | Latte, NEON a Nette konvence v MVP, **vlastní parsery** Latte a NEON v Go |
| D7 | DB | Go helper; `go-sql-driver/mysql`, `jackc/pgx/v5`, **systémová libsqlite3 přes vlastní cgo binding**, SSH tunel přes **systémové `ssh -L`** |
| D8 | Databáze | MariaDB/MySQL, PostgreSQL, SQLite |
| D9 | Aktualizace | **vlastní updater**: GitHub Releases API, podpis Ed25519 (CryptoKit), Developer ID + notarizace |
| D10 | Git / terminál | `git` CLI / **SwiftTerm** (jediná Swift knihovna) |
| D11 | Build | **SPM + vlastní skript** na sestavení `.app`; jedna Go binárka `minoride-server` (podpříkazy `phpls`, `db`, `search`) |
| D12 | Debugger | po MVP (DAP) |
| D13 | Licence | MIT |

## 1. Architektura

```
MinorIDE.app/Contents
├─ MacOS/MinorIDE                  (Swift: UI, editor, LSP klient, Git, terminál, updater UI)
├─ Helpers/minoride-server         (Go: phpls | db | search, mluví JSON-RPC/LSP přes stdio)
├─ Helpers/minoride-updater        (malý Swift CLI: výměna app po ukončení)
└─ Resources/phpstorm-stubs/       (stuby PHP funkcí a rozšíření, Apache-2.0)

Externí (hledá v PATH / projektu): gopls, php + phpstan (jen pro PHPStan a formátovače), git, ssh
```

### Swift moduly (targety v jednom `Package.swift`, kód v `Sources/<Modul>/`)

| Balíček | Odpovědnost | Závisí na AppKit |
|---|---|---|
| `MinorCore` | modely, nastavení, logování, utility | ne |
| `TextEngine` | rope, transakce editací, undo/redo, multi-selekce, kotvy (anchors), převody pozic | **ne** (čistý Swift, maximálně testovaný) |
| `Highlight` | lexery jazyků, inkrementální přelexování, páry závorek, odsazení | ne |
| `EditorKit` | editorový NSView: Core Text vykreslování, vstup (`NSTextInputClient`), kurzory, gutter, folding, popupy (completion, hover), Cmd/kolečko klik | ano |
| `LSPKit` | vlastní LSP typy a klient, sezení per jazyk a workspace | ne |
| `AnalysisKit` | PHPStan runner, převod na diagnostiky | ne |
| `ProjectKit` | strom souborů, FSEvents, index cest, fuzzy matcher, historie navigace, Local History | ne |
| `DBKit` | klient `minoride-server db`, připojení, Keychain, UI schématu, grid, SQL konzole | UI část ano |
| `GitKit` | status, diff (vlastní Myers), gutter změn, commit, blame | ne |
| `TerminalKit` | panel nad SwiftTerm | ano |
| `UpdateKit` | kontrola, stažení, ověření, předání updateru | ne |
| `App` | okna, menu, zkratky, skládání modulů | ano |

### Go modul `server/` (jen stdlib + DB ovladače, **bez cgo kromě SQLite**)

```
server/
├─ cmd/minoride-server/          main + podpříkazy phpls | db | search
├─ internal/jsonrpc/             framing (Content-Length) a dispatch
├─ internal/lsp/                 vlastní LSP typy
├─ internal/php/lexer/           lexer PHP 7.2–8.4
├─ internal/php/parser/          rekurzivní sestup + Pratt pro výrazy, zotavení z chyb
├─ internal/php/ast/             AST s pozicemi (bajtové offsety)
├─ internal/php/index/           deklarace, hierarchie, invertovaný index jmen, cache
├─ internal/php/types/           typový systém a inference
├─ internal/php/phpdoc/          parser PHPDoc
├─ internal/php/features/        completion, definition, references, rename, diagnostiky…
├─ internal/latte/               lexer + parser Latte 3
├─ internal/neon/                parser NEON + DI model Nette
├─ internal/db/                  ovladače, introspekce, SSH tunel, SQLite binding
├─ internal/search/              hledání v souborech (RE2, .gitignore)
└─ testdata/                     markerové testy, korpusy
```

### Výkonové rozpočty (platí od fáze 1, kontrolují se automaticky v CI)

| Metrika | Cíl |
|---|---|
| Studený start do okna | < 400 ms |
| Latence klávesy (keyDown → vykreslený snímek) | < 8 ms, max 16 ms |
| Otevření souboru 10 MB | < 300 ms, scroll 120 fps na ProMotion / 60 fps jinak |
| Přelexování po editaci | < 1 ms pro běžný řádek |
| Completion popup po odpovědi serveru | < 30 ms, lokální filtrování < 5 ms |
| PHP parser | běžný soubor < 2 ms; 30 000 souborů paralelně < 10 s |
| phpls: completion / definition | < 50 ms / < 20 ms |
| phpls: teplý start z cache | < 2 s |
| phpls: RAM na velkém projektu | < 600 MB |
| RAM aplikace (bez serverů) | < 300 MB |

---

## 2. Fáze a úkoly

Odhady jsou hrubé (jeden vývojář s AI). **Celé MVP: zhruba 11–15 měsíců.** Použitelné mezistupně:

- **po fázi 2**: rychlý editor s aktualizacemi, dá se denně používat;
- **po fázi 3**: plnohodnotné Go IDE;
- **po 4c**: PHP s napovídáním a proklikem;
- **po fázi 8**: kompletní MVP včetně Nette.

### Fáze 0: kostra a spiky (≈ 2 týdny)

**0.1 Build bez nástrojů třetích stran**
- `Package.swift` (executable `MinorIDE`, `minoride-updater`, knihovní balíčky), `tools/bundle.sh` sestaví `MinorIDE.app` (Info.plist, Helpers, Resources, podpis).
- `Makefile`: `build`, `test`, `run`, `server`, `bundle`, `release`.
- Hotovo když: `make run` otevře okno ze sestaveného `.app`, `make test` projde (Swift i Go).

**0.2 Spike editoru**: minimální rope a NSView, který přes Core Text vykreslí jen viditelné řádky 10 MB souboru a umí psát na konec řádku. Změřit latenci a scroll do `docs/spike-editor.md`.
- Hotovo když: rozpočty z tabulky platí i v prototypu, nebo je popsáno proč ne.

**0.3 Spike PHP parseru**: lexer PHP + parser jen deklarací (namespace, use, třídy, funkce, metody), paralelně přes `vendor/` veřejného projektu (Nette `web-project`, Laravel). Měření do `docs/spike-phpls.md`.
- Hotovo když: 30 000 souborů pod 10 s, žádný panic.

**0.4 Spike helperu**: `minoride-server db` s `ping` a `SELECT 1` nad systémovou SQLite, volané testem z `DBKit`.

### Fáze 1: vlastní editor (≈ 10–14 týdnů)

**1a. TextEngine (≈ 2–3 týdny)**
- Rope jako B-strom bloků UTF-8 (≈ 1 KB). Uzly nesou souhrn: bajty, UTF-16 jednotky, znaky, konce řádků. Převody offset ↔ řádek/sloupec ↔ UTF-16 v O(log n).
- Persistentní (copy-on-write) uzly: snapshot dokumentu je zadarmo a pozadí (lexer, LSP sync, ukládání) pracuje bez zámků.
- Editace jako transakce víc změn najednou (multi-cursor). Undo/redo s obnovou selekcí, slučování psaní (pauza 500 ms, změna slova nebo řádku).
- Multi-selekce: seřazený seznam rozsahů, slučování při překryvu.
- Kotvy, které přežijí editace (diagnostiky, záložky, Git značky, pozice v historii navigace).
- Hotovo když: unit testy včetně property-based testů (náhodné editace vs. referenční `String`) projdou a 1 000 000 náhodných editací nad 10 MB dokumentem trvá < 2 s.

**1b. Vykreslování a vstup (≈ 3–4 týdny)**
- `EditorView` (layer-backed NSView uvnitř NSScrollView), kreslí jen viditelné řádky.
- Cache layoutu řádků (`CTLine` podle obsahu řádku a stylů), invalidace jen změněných řádků.
- Rychlá cesta pro monospace, správná šířka pro široké znaky a emoji přes `CTLine`.
- Vrstvy: pozadí (aktuální řádek, selekce, výsledky hledání), text, kurzory ve vlastní vrstvě (blikání bez překreslení textu), gutter jako samostatný view.
- Vstup: plné `NSTextInputClient` (marked text, **česká diakritika přes mrtvé klávesy**, IME), mapování příkazů přes vlastní dispatcher a keymapu.
- Myš: klik, dvojklik (slovo), trojklik (řádek), tažení, Opt+tažení (sloupcový výběr), Opt+klik (další kurzor).
- Měření latence přes `NSView.displayLink` (macOS 14), výkonový test v CI.
- Základní přístupnost (VoiceOver čte aktuální řádek).
- Hotovo když: psaní, mazání a výběr v 10 MB souboru plní rozpočty a test „čšžýáíéůú“ na české klávesnici projde.

**1c. Editační příkazy (≈ 2 týdny)**
- Multi-cursor (Ctrl+G další výskyt, Ctrl+Cmd+G všechny), duplikace a přesun řádku, komentáře (Cmd+/), párování a obalování závorkami a uvozovkami, chytré odsazení podle lexeru, `.editorconfig`.
- Hledat/nahradit v souboru (regex, case, celé slovo, zachování velikosti písmen).
- Folding podle závorek a odsazení (později doplní LSP `foldingRange`).
- Checklist chování porovnaný s PhpStormem v `docs/editor-behaviors.md`. Každý bod má test.

**1d. Lexery a zvýraznění (≈ 2–3 týdny)**
- Lexer je stavový automat. Stav na začátku každého řádku se ukládá. Po editaci se přelexuje od změněného řádku, dokud se stav neshoduje s dřívějším.
- Vnořené jazyky přes zásobník módů: PHP v HTML, Latte s HTML/JS/CSS, heredoc.
- Pořadí jazyků: Go, PHP, Latte, NEON, SQL, JSON (1d); HTML, CSS/SCSS, JS/TS, YAML, Markdown, XML, `.env`, Dockerfile, Makefile, shell (1f).
- Témata světlé a tmavé, mapování tokenů na barvy v JSON.
- Golden testy: soubor → proud tokenů.

**1e. Projekt a pracovní prostředí (≈ 2 týdny)**
- Otevření složky, strom souborů (NSOutlineView, lazy), FSEvents, `vendor/` sbalený, poslední projekty, víc oken.
- Taby, split (vertikální i horizontální), „Reopen closed tab“, indikace neuložených změn.
- Nastavení: `~/Library/Application Support/MinorIDE/settings.json` + `.minoride/settings.json`, UI v SwiftUI.
- **Keymap PhpStorm (macOS)** v `docs/keymap.md`. Zkratky podle fyzických kláves (keyCode), aby fungovaly na **české klávesnici**, kde `[ ] / \` vyžadují Alt. Alternativy, např. zpět/vpřed i Cmd+Opt+←/→.
- **Kódování**: UTF-8 (s/bez BOM), Windows-1250, ISO-8859-2; zachovat CRLF/LF; přepínač ve stavovém řádku.
- **Ukládání jako PhpStorm**: auto-save při ztrátě fokusu a přepnutí tabu (zapínatelné), **Local History** (snímek při uložení, 14 dní, náhled a obnovení), obnova sezení a obnova po pádu.
- Velké a minifikované soubory (> 5 MB nebo řádek > 10 000 znaků): zjednodušený režim bez zvýraznění a analýzy.

**1f. Dokončení (≈ 1–2 týdny)**: zbylé lexery, **zalamování řádků** (mapování řádek ↔ vizuální řádky, vypnuté výchozí, zapnuté pro Markdown), sticky header s aktuální funkcí.

### Fáze 2: vydávání a vlastní updater (≈ 2 týdny)

**Vydání (GitHub Action `.github/workflows/release.yml`, runner `macos-15`)**
1. Spouští se tagem `vX.Y.Z`.
2. Build Release, `minoride-server` pro `darwin/arm64`, podpis Developer ID s hardened runtime (nejdřív helpery, pak app), notarizace `xcrun notarytool submit --wait`, `xcrun stapler staple`.
3. `MinorIDE-X.Y.Z.zip` (`ditto -c -k --keepParent`) a `.dmg` pro první instalaci.
4. `tools/signrelease` (Go, stdlib `crypto/ed25519`) vytvoří `MinorIDE-X.Y.Z.zip.sig`. Privátní klíč je v GitHub Secrets.
5. Nahraje zip, sig a dmg jako assety release. Popis release slouží jako release notes.

**Kontrola a instalace v aplikaci (`UpdateKit` + `minoride-updater`)**
- `GET https://api.github.com/repos/novami/minor-ide/releases/latest` s `ETag` (limit 60 dotazů za hodinu bez přihlášení stačí). Pre-release se ignorují. Porovnání semver.
- Nastavení → Aktualizace: **„Automaticky kontrolovat aktualizace“** (výchozí zapnuto), interval denně/týdně, „Přeskočit tuto verzi“. Menu **MinorIDE → Zkontrolovat aktualizace…**
- Při nové verzi okno s release notes (Markdown přes vestavěný `AttributedString(markdown:)`) a tlačítkem **Aktualizovat**.
- Po kliknutí:
  1. stažení s průběhem do `~/Library/Caches/MinorIDE/updates/`;
  2. **ověření Ed25519 podpisu** (CryptoKit, veřejné klíče zabudované v app, podporují rotaci: aktuální + další);
  3. rozbalení `ditto -x -k`;
  4. **ověření code signature** nové app (`SecStaticCodeCheckValidity` s požadavkem na stejné Team ID);
  5. nabídnutí uložení neuložených souborů;
  6. kopie `minoride-updater` do tmp a spuštění s PID, cestou staré a nové app; aplikace se ukončí;
  7. updater počká na ukončení, starou app přesune do koše, novou dá na její místo, spustí ji. Při chybě vrátí starou.
- App musí běžet z `/Applications` (jinak ji macOS spouští z izolované kopie). Při startu odjinud nabídnout přesun. Bez práva zápisu do `/Applications` ukázat návod místo pokusu.
- Hotovo když: 0.1.0 se po vydání `v0.1.1` aktualizuje jedním kliknutím; archiv se špatným podpisem nebo cizím Team ID je odmítnut; přerušené stažení nic nerozbije.

### Fáze 3: LSP klient a Go (≈ 3 týdny)

3.1 **LSPKit**: vlastní typy (jen použitá podmnožina), spuštění serveru, `initialize`, inkrementální `didChange` ze snapshotu TextEngine, `didOpen/didClose/didSave`, `$/progress` ve stavovém řádku, `$/cancelRequest`, restart při pádu (max 3×/min), log v panelu „Language Servers“.
3.2 **Pozice**: vyjednat `positionEncoding: utf-8`, fallback UTF-16 přes převody z rope. Testy s diakritikou a emoji.
3.3 **gopls**: detekce v PATH a `~/go/bin`, nabídka instalace, `staticcheck: true`, `go.work` a víc modulů.
3.4 **Napovídání**: vlastní popup (NSPanel), trigger znaky, Ctrl+Space, **lokální fuzzy filtrování** (nový dotaz jen při `isIncomplete`), `completionItem/resolve` pro dokumentaci, snippety s Tab skoky, `additionalTextEdits` (auto-import).
3.5 **Proklik**: **klik kolečkem** (`otherMouseDown`, `buttonNumber == 2`) a **Cmd+klik** → `definition`; podtržení symbolu při držení Cmd; víc cílů → popup; klik na samotnou deklaraci → použití. Cmd+B, Cmd+Opt+B (implementace), Shift+Cmd+B (typ), Opt+F7 (použití do panelu).
3.6 **Historie navigace**: zpět/vpřed (zkratky z keymapy), boční tlačítka myši 3/4, Recent files (Cmd+E).
3.7 Hover, `signatureHelp`, diagnostiky (vlnovky, gutter, scrollbar, panel Problems, F2/Shift+F2), quick-fixy Opt+Enter, rename Shift+F6 s náhledem, formátování Cmd+Opt+L a při uložení, semantic tokens přes lexer.
- Hotovo když: reálný Go projekt má všechno z 3.4–3.7, latence klávesy beze změny, pád gopls editor přežije.

### Fáze 4: PHP jazykový server (≈ 14–20 týdnů)

**Markerové testy od prvního dne** (`server/testdata/php/`):

```php
$user = new User();
$user->/*|complete: getName, getEmail*/;
$x = $user->getName/*|def: User.php:12*/();
```

**4a. Lexer a parser PHP 7.2–8.4 (≈ 5–7 týdnů)**
- Lexer: všechny tokeny včetně inline HTML, `<?=`, heredoc/nowdoc s interpolací, `?->`, atributy `#[`, `match`, enumy, `readonly`, property hooks a asymetrická viditelnost (8.4), pojmenované argumenty, first-class callable `f(...)`, číselné oddělovače.
- Parser: rekurzivní sestup pro příkazy, Pratt pro výrazy s precedencí PHP. AST s bajtovými pozicemi a komentáři navázanými na uzly (PHPDoc).
- **Zotavení z chyb**: neočekávaný token → uzel `Missing`, synchronizace na `;`, `}` nebo klíčové slovo příkazu. Nikdy panic, vždy strom + seznam chyb. Klíčové pro napovídání v rozepsaném kódu (`$user->` na konci řádku).
- Parser přijímá nadmnožinu syntaxe. Chyby podle verze PHP projektu hlásí samostatná kontrola.
- Celý soubor se po změně parsuje znovu (běžný soubor < 2 ms). Inkrementální parsování jen pokud to měření ukáže jako nutné.
- Testy: korpus `Zend/tests` z php-src a `vendor/` velkých projektů (0 panic, platné soubory bez chyb), **Go fuzzing** (`go test -fuzz`), golden testy AST.
- PHPDoc parser: `@var @param @return @throws @template(-covariant) @extends @implements @method @property(-read/-write) @mixin @deprecated`, typy včetně generik, `array{shape}`, `list<T>`, `class-string<T>`.

**4b. Index (≈ 2–3 týdny)**
- Zdroje: projekt; `vendor/` podle Composeru (`installed.json`, `autoload_psr4.php`, `autoload_classmap.php`); phpstorm-stubs filtrované podle verze PHP projektu.
- Deklarace s FQN, umístěním, signaturou a PHPDoc; rozlišení jmen (namespace, `use` všech druhů, aliasy, `self/static/parent`, fallback globálních funkcí); hierarchie a podtypy.
- **Cache na disku** (`~/Library/Caches/MinorIDE/phpls/<hash>/`, gob, per soubor hash obsahu), přeindexování jen změněných souborů, `didChangeWatchedFiles`, změna `composer.lock` → přeindexovat `vendor/`.
- Paralelní indexace, průběh přes `$/progress`, odpovídá i během indexace.
- LSP: `documentSymbol`, `workspace/symbol`, `definition` jmen, `foldingRange`, syntaktické chyby.

**4c. Typová inference a napovídání (≈ 3–4 týdny)**
- Typy: skaláry, `mixed`, `null`, nullable, union, intersection, třídy, `array<K,V>`, `list<T>`, shapes, `iterable<T>`, `callable`, `static/self/$this`, generika `@template` (třídy i metody), `class-string<T>`.
- Inference (líně, memoizace per verze souboru): nativní typy, PHPDoc, přiřazení, `new`, řetězení volání, narrowing (`instanceof`, `is_*`, `!== null`, early return), `foreach`, closure a arrow funkce, inline `@var`, destrukce, ternár, `??`, `match`.
- Magie: `__get/__call/__callStatic` přes `@property/@method`, `@mixin`, Nette SmartObject.
- Scope proměnných: parametry, přiřazení před kurzorem, `use (...)`, `global`, `static`.
- LSP: **`completion`** (členy za `->`, `?->`, `::`; třídy, funkce, konstanty s **auto-importem**; proměnné; klíčová slova; pojmenované argumenty), **řazení** podle očekávaného typu, blízkosti scope a nedávného použití; `definition` členů, `typeDefinition`, `implementation`, `hover`, `signatureHelp`.
- Hotovo když: markerové testy pokrývají každý bod a v reálném Nette projektu funguje napovídání a proklik kolečkem na řetězená volání.

**4d. Použití, přejmenování, inspekce (≈ 2–3 týdny)**
- `references`: kandidáti z invertovaného indexu jmen, ověření inferencí, streamované výsledky.
- `rename`: třídy (včetně souboru podle PSR-4), metody, vlastnosti, proměnné, konstanty; ne symboly z `vendor/`.
- Inspekce při psaní: neznámá třída/funkce/metoda/vlastnost, nepoužitý `use` a proměnná, počet argumentů, volání na možném `null`, syntaxe mimo verzi PHP projektu, přístup k private/protected.
- Quick-fixy: import třídy, odstranit nepoužité `use`, implementovat metody rozhraní, vytvořit metodu/vlastnost, doplnit PHPDoc.

**4e. PHPStan, formátování, Docker (≈ 1 týden, `AnalysisKit`)**
- `phpstan analyse --error-format=json --no-progress <soubor>` při uložení (debounce 300 ms, rušení běžícího), `phpstan.neon(.dist)` projektu, sloučení s diagnostikami phpls bez duplicit, „Analyzovat celý projekt“.
- PHP CS Fixer / PHP_CodeSniffer z `vendor/bin`.
- **PHP v Dockeru**: „spouštět PHP nástroje přes“ lokálně / `docker compose exec <služba>` s mapováním cest.

### Fáze 5: navigace v projektu (≈ 1–2 týdny)

5.1 Index cest v paměti + vlastní fuzzy matcher (začátky slov, camelCase, cesta, nedávné soubory výš).
5.2 **Search Everywhere** (dvojité Shift): soubory, symboly z gopls i phpls, akce IDE. Cmd+Shift+O soubor, Cmd+Opt+O symbol.
5.3 **Find in Files** (Cmd+Shift+F) přes `minoride-server search` (RE2, `.gitignore`, paralelně, streamované výsledky), náhled, nahrazení.
5.4 Struktura souboru (Cmd+F12) a breadcrumbs.
- Hotovo když: v projektu s 20 000 soubory najde soubor do 50 ms od stisku klávesy a Find in Files vrátí první výsledky do 100 ms.

### Fáze 6: DB klient (≈ 4 týdny)

6.1 **`minoride-server db`**
- Ovladače `go-sql-driver/mysql`, `pgx/v5`, vlastní cgo binding na systémovou `libsqlite3`.
- Metody `connect`, `disconnect`, `listDatabases`, `listSchemas`, `listTables`, `describeTable` (sloupce, indexy, FK, DDL), `query` (stream po stránkách), `fetchMore`, `cancel` (přes `context`), `execute`, `beginTx/commit/rollback`.
- **SSH tunel přes systémové `ssh -N -L`** (respektuje `~/.ssh/config`, ProxyJump, ssh-agent), hlídání a ukončení procesu.
- Bezztrátové typy: NULL, binární jako base64, velká čísla jako string, datum ISO 8601.
- Integrační testy proti Docker Compose (MariaDB 11, PostgreSQL 17), build tag `integration`.
6.2 Připojení: dialog (host, port, uživatel, DB, SSH, TLS), „Test připojení“, `.minoride/datasources.json` nebo globálně, **hesla jen v Keychain**.
6.3 Prohlížeč schématu (lazy strom, obnovení).
6.4 Data grid: NSTableView (view-based), stránkování po 500, řazení, filtr, NULL, JSON/BLOB prohlížeč, kopírování jako TSV/CSV/INSERT.
6.5 Editace dat: lokální změny, „Submit“ s **náhledem SQL**, transakce, jen tabulky s PK.
6.6 SQL konzole: vlastní SQL lexer, Cmd+Enter spustí výraz pod kurzorem, výsledky v tabech, historie, napovídání tabulek a sloupců z cache schématu.
6.7 Export do CSV/JSON.
- Hotovo když: připojení k MariaDB přímo i přes SSH, editace dat s náhledem SQL a zrušení 30s dotazu fungují.

### Fáze 7: Git a terminál (≈ 2 týdny)

7.1 Gutter změn proti HEAD (vlastní Myers diff nad rope snapshotem), rollback bloku.
7.2 Panel změn, side-by-side diff, commit s výběrem souborů, amend.
7.3 Blame v gutteru, přepínání větví, pull/push s výstupem.
7.4 Terminál (SwiftTerm) jako spodní panel, víc tabů, start v kořeni projektu.

### Fáze 8: Nette, Latte, NEON (≈ 5–7 týdnů)

Cíl: Nette 3.x, Latte 3.x, struktura `app/UI/<Name>/` i starší `app/Presenters/` + `templates/`.

8.1 **Latte parser v Go**: tagy, `n:` atributy, `{$var}`, filtry, komentáře, bloky. PHP výrazy uvnitř tagů parsuje parser z 4a. Zvýraznění řeší lexer z 1d.
8.2 **NEON parser v Go** (podle specifikace NEON): `services:`, `parameters:`, `includes:`, entity.
8.3 **DI model Nette**: služby, typy, autowiring, proklik z NEON na třídu, napovídání tříd v NEON, `inject*` metody a `#[Inject]`.
8.4 **Presenter ↔ šablona**: mapování akce/render na šablonu (obě struktury), gutter ikona, „Přejít na šablonu / presenter“. Typy proměnných šablony: `{templateType}`, `{varType}`, `{var}`, `$this->template->x`, template třídy. Napovídání v Latte: proměnné a členy, tagy, filtry, `n:` atributy.
8.5 **Proklik v Latte**: `{include}`, `{layout}`, `{import}`, `{block}/{define}`, `{link}` a `n:href` → metoda presenteru, `{control}` → `createComponent…()`, členy proměnných.
8.6 **Proklik v PHP**: `link()`, `redirect()`, `forward()` → presenter a akce; `$this['name']` → `createComponent…()`.
8.7 Inspekce Latte: neznámá proměnná a filtr, neexistující šablona v `{include}`, neexistující akce v `{link}`.
- Hotovo když: v reálném Nette 3.2 projektu funguje proklik kolečkem presenter ↔ šablona ↔ komponenta a napovídání členů proměnných v Latte.

### Po MVP
Debugger (DAP: `dlv dap`, Xdebug), SQL v PHP řetězcích, run konfigurace a test runner, golangci-lint, inlay hinty, live templates, refaktoringy extract/inline.

---

## 3. Rizika

| # | Riziko | Dopad | Opatření |
|---|---|---|---|
| R1 | Vlastní editor má stovky drobných chování (IME, selekce, undo, scroll), kde chyby hned bolí | vysoký | TextEngine bez AppKit s property-based testy, checklist `editor-behaviors.md`, každodenní používání od fáze 2 |
| R2 | Vlastní PHP parser: správnost napříč PHP 7.2–8.4 | vysoký | korpus php-src + vendor, fuzzing, golden testy, parser nikdy nepanikaří |
| R3 | Vlastní PHP server je nejrizikovější část rozsahem | vysoký | podfáze 4a–4e, každá použitelná; PHPStan kryje hlubokou analýzu |
| R4 | PHP napovídání až po 4c (≈ 8 měsíců od začátku) | střední | pořadí drží editor a Go použitelné dřív |
| R5 | Regrese plynulosti | vysoký | výkonové testy psaní a scrollu v CI, build selže při překročení rozpočtu |
| R6 | Řazení napovídání (PhpStorm působí „chytře“ hlavně díky němu) | střední | řazení podle typu, scope a nedávného použití; testy pořadí top 3 |
| R7 | Chyba vlastního updateru rozbije instalaci | vysoký | dvojí ověření (Ed25519 + code signature), atomická výměna s návratem, test přerušeného stažení |
| R8 | Únik Ed25519 klíče nebo certifikátu Developer ID | vysoký | jen v GitHub Secrets a Keychainu, offline záloha, rotace klíče (app zná aktuální i další), postup v `docs/release.md` |
| R9 | gopls na velkých monorepech 1–2 GB RAM | střední | `directoryFilters`, varování v UI |
| R10 | Celkový rozsah 11–15 měsíců | vysoký | striktně po fázích, vydávat a používat průběžně |

## 4. Otevřené otázky

- **Q1** Testovací projekty: zatím veřejné open-source (Nette `web-project`, Laravel, velké Go repo), vlastní doplnit později.

---

## 5. Pravidla pro implementátora (Sonnet)

Po založení repozitáře zkopírovat do `CLAUDE.md` projektu.

- Pracuj po úkolech v pořadí fází. Úkol končí splněním **Hotovo když**, testem hlavní cesty a commitem.
- Commity malé, jen vlastní soubory (`git commit -- <soubory>`), bez AI podpisů. Nikdy `git push` bez vyžádání.
- **Žádná nová závislost bez souhlasu uživatele.** Povolené jsou jen: SwiftTerm, `go-sql-driver/mysql`, `jackc/pgx/v5` (a jejich závislosti), `golang.org/x/*`, phpstorm-stubs (data). Systémové frameworky macOS a stdlib Go jsou volné.
- Na hlavním vlákně jen UI. Každá změna v editační cestě musí projít výkonovým testem.
- phpls: každá nová schopnost začíná markerovým testem. Parser: každá opravená chyba dostane fixture.
- Hesla a tajemství jen v Keychainu, nikdy do logů.
- Když se rozhodnutí z plánu ukáže jako špatné (např. výsledek spiku), zastav a popiš varianty. Technologii neměň sám.
- Testy: Swift Testing, `go test ./...`, fuzzing parseru, integrační DB testy za tagem `integration`. Spouštět přes `make test` (obchází chybu SwiftPM s Command Line Tools bez Xcode).

Struktura repozitáře:

```
minor-ide/
├─ Package.swift, Makefile, CLAUDE.md, LICENSE (MIT)
├─ Sources/                    (MinorIDE app, minoride-updater, MinorCore, TextEngine, Highlight,
│                               EditorKit, LSPKit, AnalysisKit, ProjectKit, DBKit, GitKit,
│                               TerminalKit, UpdateKit)
├─ Tests/                      (<Modul>Tests)
├─ server/                     (Go: minoride-server)
├─ tools/                      (bundle.sh, signrelease/)
├─ Resources/                  (Info.plist, ikony, témata, phpstorm-stubs)
├─ docs/                       (ANALYZA, PLAN, ZAVISLOSTI, keymap, editor-behaviors, release, spike-*)
└─ .github/workflows/          (ci.yml, release.yml)
```
