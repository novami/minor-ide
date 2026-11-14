# Implementační plán: MinorIDE, nativní IDE pro Go a PHP (macOS, Apple Silicon)

- Název: **MinorIDE** (`MinorIDE.app`, bundle id `cz.novami.minoride`), repozitář `github.com/novami/minor-ide`, licence **MIT**.
- Cílový stroj: M2, 16 GB RAM, macOS 14+.
- Implementuje: Sonnet, po úkolech v pořadí níže. Každý úkol má **Hotovo když**.
- Analýza konkurence: [ANALYSIS.md](ANALYSIS.md). Volba závislostí: [DEPENDENCIES.md](DEPENDENCIES.md).

**Filozofie: minimum knihoven třetích stran.** Vlastní je editor, zvýraznění, všechny parsery, LSP, updater, hledání, SFTP/FTPS klient i build. Knihovny zůstávají jen tam, kde by vlastní implementace stála měsíce bez přínosu: SwiftTerm, ovladače MySQL a PostgreSQL a data stubů PHP.

**Bezpečnost je vlastnost produktu, ne dodatek.** IDE drží hesla k databázím a serverům a spouští cizí kód (nástroje projektu). Pravidla jsou v sekci [Bezpečnost](#bezpečnost) a platí pro každou fázi.

---

## 0. Rozhodnutí (potvrzená)

| # | Rozhodnutí | Volba |
|---|---|---|
| D1 | UI | Swift 6 + AppKit; SwiftUI jen pro nastavení a dialogy |
| D2 | Editor | **vlastní**: rope + vykreslování přes Core Text, 0 závislostí |
| D3 | Zvýraznění | **vlastní inkrementální lexery** (stav na začátku řádku) ve Swiftu |
| D4 | Go inteligence | gopls přes LSP, `staticcheck` zapnutý |
| D5 | PHP inteligence | **vlastní jazykový server v Go s vlastním parserem**, PHP **7.2 až aktuální stabilní verze** (nyní 8.5), doplněný o PHPStan |
| D6 | Nette | Latte, NEON a Nette konvence v MVP, **vlastní parsery** Latte a NEON v Go |
| D7 | DB | Go helper; `go-sql-driver/mysql`, `jackc/pgx/v5`, **systémová libsqlite3 přes vlastní cgo binding**, SSH tunel přes **systémové `ssh -W`** jako vlastní dialer ovladače (žádný lokální port) |
| D8 | Databáze | MariaDB/MySQL, PostgreSQL, SQLite |
| D9 | Aktualizace | **vlastní updater**: GitHub Releases API, podpis Ed25519 (CryptoKit; **podepisuje se lokálně, klíč není na GitHubu**), Developer ID + notarizace |
| D10 | Git / terminál | `git` CLI / **SwiftTerm** (jediná Swift knihovna) |
| D11 | Build | **SPM + vlastní skript** na sestavení `.app`; jedna Go binárka `minoride-server` (podpříkazy `phpls`, `db`, `search`, `remote`, `debug`) |
| D12 | Debugger a testy | **v MVP** (fáze 7b): vlastní DAP klient, `dlv dap` pro Go, vlastní adaptér Xdebug DBGp → DAP v `minoride-server debug`; test runner pro `go test`, PHPUnit a Nette Tester |
| D13 | Licence | MIT (vlastní kód). Závislosti: MIT, BSD, Apache-2.0, **MPL-2.0 jen `go-sql-driver/mysql`** (souborový copyleft, nemodifikujeme, uvedeno v Poděkováních) |
| D14 | Vzdálené soubory | **vlastní SFTP v3 klient v Go nad systémovým `ssh -s sftp`** (0 závislostí; `~/.ssh/config`, ssh-agent, ProxyJump, sdílené spojení) |
| D15 | FTP | **SFTP + FTPS** (FTP přes TLS, vlastní klient v Go nad stdlib `crypto/tls`). **Nešifrované FTP ne.** |
| D16 | SSH | vždy **systémové OpenSSH** (`ssh`, `ssh -s sftp`, `ssh -W`; `ssh -L` jen pro tunely, které si uživatel sám založí), sdílené spojení přes `ControlMaster`; ověřování klíčů serveru přes `known_hosts`, nikdy `StrictHostKeyChecking=no` |
| D17 | rsync | systémový `rsync` (na macOS 15.4+ je to `openrsync`) nebo Homebrew `rsync` 3.x, pokud je nainstalovaný; vždy náhled (`--dry-run`) před mazáním |
| D18 | Důvěra v projekt | **Omezený režim** pro neznámé projekty (jako VS Code): bez spouštění nástrojů a příkazů z nastavení projektu, dokud uživatel neklikne „Důvěřovat“. V Omezeném režimu se také nečte `.minoride/local.json` a nespouští se **Git** (konfigurace repozitáře umí spustit příkaz, např. `core.fsmonitor`), **gopls**, externí LSP servery, Docker, run konfigurace ani debugger. Důvěra se ukládá **mimo projekt** |
| D19 | Hesla | jen **Klíčenka macOS**: souborová přihlašovací klíčenka s ACL vázaným na podpis aplikace (do iCloudu se nesynchronizuje, nepotřebuje provisioning profil); **bez Touch ID** (rozhodnutí uživatele) |
| D20 | Telemetrie | **žádná**. Žádná analytika ani odesílání pádů. Síť jen pro kontrolu aktualizací (vypnutelné) a pro spojení, která uživatel založí |
| D21 | Sandbox | **bez App Sandbox** (IDE musí spouštět `git`, `go`, `php`, `ssh`…), distribuce mimo App Store s Developer ID, hardened runtime bez výjimek |
| D22 | PATH | GUI aplikace z Finderu nemá PATH z terminálu (chybí `/opt/homebrew/bin`). Při startu se jednou načte prostředí z přihlašovacího **interaktivního** shellu (`$SHELL -l -i -c`, výstup mezi značkami kvůli výpisům z `.zshrc`, časový limit): `PATH`, `GOPATH`, `GOPRIVATE`, `GOFLAGS`, `SSH_AUTH_SOCK`. Při selhání záložní cesty `/opt/homebrew/bin`, `/usr/local/bin`, `~/go/bin` |
| D23 | Ostatní jazyky (JS/TS, CSS, HTML…) | **externí LSP servery podle nastavení** (`settings.json`: jazyk → příkaz a argumenty) nad `LSPKit`; nic se nepřibaluje, bez serveru zůstává zvýraznění |
| D24 | Síťové porty | helpery mluví jen přes stdin/stdout. Jediné výjimky: **ladění** (`dlv dap` a Xdebug DBGp, jen `127.0.0.1`, jen po dobu ladicí relace) a **askpass** (unixový socket v adresáři `0700`, jednorázový token) |

## 1. Architektura

```
MinorIDE.app/Contents
├─ MacOS/MinorIDE                  (Swift: UI, editor, LSP klient, Git, terminál, updater UI)
├─ Helpers/minoride-server         (Go: phpls | db | search | remote | debug, mluví JSON-RPC/LSP/DAP přes stdio)
├─ Helpers/minoride-askpass        (malý Swift CLI: SSH_ASKPASS/GIT_ASKPASS, heslo si vyžádá od IDE)
├─ Helpers/minoride-updater        (malý Swift CLI: výměna app po ukončení)
└─ Resources/php-stubs/            (stuby PHP funkcí a rozšíření; zdroj viz Q2)

Externí (hledá v PATH / projektu): gopls, php + phpstan (jen pro PHPStan a formátovače), git, ssh, rsync, docker, dlv, externí LSP servery
```

### Externí nástroje

Nastavení → Nástroje ukazuje každý nástroj s cestou a verzí, umožní cestu přepsat a nabídne instalaci (Homebrew / `go install`). Chybějící nástroj nikdy neblokuje editor, jen vypne danou funkci s vysvětlením.

| Nástroj | K čemu | Minimální verze | Když chybí |
|---|---|---|---|
| `git` | Git integrace | 2.30 | nabídnout `xcode-select --install` |
| `go`, `gopls` | Go inteligence | Go 1.22, gopls 0.16 | nabídnout `go install golang.org/x/tools/gopls@latest` |
| `php` | PHPStan, formátovače | 7.2 | PHP analýza běží dál (vlastní server PHP nepotřebuje) |
| `phpstan`, `php-cs-fixer`, `phpcs` | analýza, formátování | z `vendor/bin` projektu, jinak globální | funkce skrytá |
| `ssh` | SSH, SFTP, tunely | systémový OpenSSH | součást macOS |
| `rsync` | synchronizace | `openrsync` (macOS) nebo rsync 3.x | součást macOS |
| `docker` | PHP v kontejneru | 24 | volba skrytá |
| `dlv` | ladění Go | 1.22 | nabídnout `go install github.com/go-delve/delve/cmd/dlv@latest` |
| Xdebug (rozšíření PHP) | ladění PHP | 3.0 | návod k zapnutí (`xdebug.mode=debug`) |
| externí LSP servery (např. `typescript-language-server`) | JS/TS, CSS, HTML (D23) | podle nastavení | zůstává jen zvýraznění |

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
| `RunKit` | run konfigurace, test runner, vlastní DAP typy a klient, UI ladění (breakpointy, zásobník, proměnné) | UI část ano |
| `UpdateKit` | kontrola, stažení, ověření, předání updateru | ne |
| `SecretsKit` | Klíčenka (uložení, čtení, smazání hesel podle id), schránka pro hesla, Omezený režim (důvěra projektů), načtení prostředí (D22), socket pro askpass (D24) | ne |
| `RemoteKit` | klient `minoride-server remote`: servery, mapování, vzdálený prohlížeč, fronta přenosů, nasazování, rsync | UI část ano |
| `App` | okna, menu, zkratky, skládání modulů | ano |

### Go modul `server/` (jen stdlib + DB ovladače, **bez cgo kromě SQLite**)

```
server/
├─ cmd/minoride-server/          main + podpříkazy phpls | db | search | remote | debug
├─ internal/jsonrpc/             framing (Content-Length) a dispatch
├─ internal/lsp/                 vlastní LSP typy
├─ internal/dbgp/                adaptér Xdebug DBGp → DAP
├─ internal/php/lexer/           lexer PHP 7.2–8.5
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
├─ internal/ssh/                 správa systémového ssh (ControlMaster, tunely, known_hosts, askpass)
├─ internal/sftp/                vlastní SFTP v3 klient nad `ssh -s sftp`
├─ internal/ftps/                vlastní FTPS klient (explicitní TLS, pasivní režim, MLSD)
├─ internal/sync/                porovnání stromů, plán přenosů, rsync náhled a běh
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
| Nečinnost (okno na pozadí) | ~0 % CPU: blikání kurzoru a časovače se zastaví, App Nap povolen |
| Jakákoli síťová nebo procesová operace | nikdy na hlavním vlákně, vždy s časovým limitem a možností zrušit |

Další pravidla výkonu:
- **Líný start**: jazykové servery, DB helper a SSH spojení se spouští až při prvním použití, ne při otevření projektu.
- **Tlak na paměť**: `DispatchSource.makeMemoryPressureSource` → zahodit cache rozvržení řádků, zavřených souborů a výsledků hledání.
- **Na baterii** se indexace a PHPStan celého projektu spouští s nižší prioritou (`QualityOfService.utility`).
- **Výchozí vyloučení** z indexace a hledání: `.git`, `node_modules`, `vendor/**/tests`, `temp/`, `log/`, `var/cache` (nastavitelné).

### Standardy macOS (Apple Human Interface Guidelines)

MinorIDE se musí chovat jako nativní Mac aplikace, aby se Mac uživatel hned zorientoval. Závazný zdroj: [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/). Konkrétně:

| Oblast | Pravidlo |
|---|---|
| **Lišta menu** | Pořadí: *MinorIDE, Soubor, Úpravy, Formát, Zobrazení, Navigace, Kód, Okno, Nápověda*. Aplikační menu: O aplikaci, Nastavení… (⌘,), Služby, Skrýt (⌘H), Skrýt ostatní (⌥⌘H), Zobrazit vše, Ukončit (⌘Q). Úpravy vždy obsahují Zpět/Znovu, Vyjmout/Kopírovat/Vložit, Vybrat vše a Najít. Okno: Minimalizovat (⌘M), Zvětšit, Převést vše do popředí. Nápověda má systémové vyhledávání v menu. Každá akce IDE je dostupná z menu (i když má zkratku). |
| **Zkratky** | Systémové zkratky se nikdy nepřepisují (⌘Q, ⌘H, ⌘M, ⌘Tab, ⌘mezerník, ⌘\`, ⌃⌘F). Standardní textové zkratky platí vždy (⌘Z, ⇧⌘Z, ⌘X/C/V, ⌘A, ⌘F, ⌘G, ⌘S, ⌘W, ⌘N, ⌘O, ⌘,). Vlastní zkratky IDE (`docs/keymap.md`) jen tam, kde nekolidují se systémem: ⌘E zůstává „Použít výběr pro hledání“ (Recent files má ⇧⌘E) a ⌃mezerník bývá obsazený přepínáním vstupních zdrojů, proto má napovídání i ⌥Esc. Písmenné zkratky se řídí **znakem** (jako systém; na QWERTZ je ⌘Z na klávese Z), fyzickou pozicí jen interpunkce. |
| **Okna** | Projektové okno: postranní panel vlevo (strom souborů, jako Finder/Xcode), editor uprostřed, inspektor/panely vpravo a dole skrývatelné, sjednocený toolbar. Plná obrazovka, obnova oken po restartu, Nedávné (`NSDocumentController`), otevření přetažením na Dock nebo okno a z Finderu („Otevřít v aplikaci“). |
| **Dialogy** | Dotazy k oknu jako *sheet* (ne modální dialog celé aplikace). Uložit změny: *Uložit / Zrušit / Neukládat* se standardními texty. Standardní `NSOpenPanel`/`NSSavePanel`. |
| **Nastavení** | Samostatné okno *Nastavení* (⌘,) s kartami v toolbaru, změny platí okamžitě, bez OK/Storno. Stejná data jako `settings.json`. |
| **Vzhled** | Systémové barvy a akcentní barva, světlý i tmavý režim, systémové písmo v UI, ikony SF Symbols, kontextová menu na pravé tlačítko, gesto přejetí dvěma prsty = zpět/vpřed v navigaci. |
| **Přístupnost** | VoiceOver, Zvýšit kontrast, Omezit pohyb, Omezit průhlednost, plné ovládání klávesnicí. |
| **Oprávnění** | `Info.plist` má popisy pro systémové dotazy: `NSLocalNetworkUsageDescription` (DB a SSH v lokální síti, macOS 15+), `NSDocumentsFolderUsageDescription`, `NSDesktopFolderUsageDescription`, `NSDownloadsFolderUsageDescription`. Helpery a procesy z terminálu systém přičítá MinorIDE. |
| **Jazyk** | Výchozí angličtina (US), **čeština vždy kompletní** (kontroluje `make test` a CI), další jazyky jedním příkazem `make l10n-new LANG=xx`. Aplikace se řídí jazykem systému. Texty jen přes `L("…")`, nikdy napevno. Množná čísla se skloňují podle jazyka (`LP`, `.stringsdict`: 1 mezera / 2 mezery / 5 mezer). Postup: [translations.md](translations.md). |

### Uživatelský zážitek (UX)

| Oblast | Pravidlo |
|---|---|
| **Uvítací okno** | Bez otevřeného projektu: nedávné projekty, Otevřít složku, Klonovat z Gitu, Připojit se k serveru (jako uvítání v Xcode). |
| **První spuštění** | Kontrola nástrojů (tabulka výše) s jedním tlačítkem pro instalaci chybějících; žádný průvodce s deseti kroky. |
| **Stavový řádek** | Jazyk, konce řádků, odsazení, kódování (klik = přepnout), pozice kurzoru, Git větev, stav indexace, stav připojení k serveru, režim důvěry projektu. |
| **Práce na pozadí** | Indexace, PHPStan, nahrávání, rsync nikdy neblokují UI: průběh ve stavovém řádku a panelu Úlohy s možností zrušit. Modální průběh je zakázaný. |
| **Chyby** | Lidsky a v jazyce UI: co se stalo, proč, co s tím (tlačítko akce). Technický detail rozbalitelný. Nikdy jen „Error -1“. |
| **Prázdné stavy** | Každý panel bez obsahu říká, co do něj patří a jak ho naplnit. |
| **Velikost písma** | ⌘+ / ⌘− / ⌘0 v editoru, volitelné ligatury, výběr monospace písma. |
| **Bezpečné akce** | Destruktivní operace (smazání souboru, sync s mazáním, DELETE bez WHERE, nahrání na produkci) vždy s náhledem a potvrzením; smazané soubory do Koše, ne natrvalo. |
| **Produkční prostředí** | Server nebo databáze označené jako produkce mají červený pruh v okně, potvrzení zápisů a výchozí režim jen pro čtení. |

---

## 2. Fáze a úkoly

Odhady jsou hrubé (jeden vývojář s AI). Součet fází je 61–76 týdnů; s rezervou zhruba 30 % na to, co plán nevidí, **celé MVP: 18–23 měsíců**. Použitelné mezistupně:

- **po fázi 2b**: rychlý editor s aktualizacemi, otevřením souboru podle jména, hledáním v souborech, terminálem a Git gutterem; dá se denně používat;
- **po fázi 3**: Go IDE (ladění a testy až v 7b);
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

### Fáze 1: vlastní editor (≈ 12–16 týdnů)

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
- Vstup: plné `NSTextInputClient` (marked text, **česká diakritika přes mrtvé klávesy**, IME), mapování příkazů přes vlastní dispatcher a keymapu; klávesy mimo keymapu jdou přes `interpretKeyEvents`/`doCommandBySelector`, aby platily systémové vazby (⌃A, ⌃E, ⌃K, ⌥←, `DefaultKeyBinding.dict`).
- Myš: klik, dvojklik (slovo), trojklik (řádek), tažení, Opt+tažení (sloupcový výběr), Opt+klik (další kurzor).
- Měření latence přes `NSView.displayLink` (macOS 14), výkonový test v CI.
- Základní přístupnost (VoiceOver čte aktuální řádek); plná přístupnost je úkol v 1f.
- Hotovo když: psaní, mazání a výběr v 10 MB souboru plní rozpočty a test „čšžýáíéůú“ na české klávesnici projde.

**1c. Editační příkazy (≈ 2 týdny)**
- Multi-cursor (Ctrl+G další výskyt, Ctrl+Cmd+G všechny), duplikace a přesun řádku, komentáře (Cmd+/), párování a obalování závorkami a uvozovkami, chytré odsazení podle lexeru, „Převést odsazení“ (tabulátory ↔ mezery v celém souboru). Tab, Shift+Tab a Enter s převzetím odsazení jsou hotové.
- Hledat/nahradit v souboru (regex, case, celé slovo, zachování velikosti písmen).
- Folding podle závorek a odsazení (později doplní LSP `foldingRange`).
- Checklist chování editoru v `docs/editor-behaviors.md`. Každý bod má test.

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
- **Keymapa** v `docs/keymap.md`. Písmenné zkratky podle znaku (QWERTZ i QWERTY), **interpunkční zkratky podle fyzické klávesy** (keyCode), aby fungovaly na **české klávesnici**, kde `[ ] / \` vyžadují Alt; menu ukazuje skutečnou klávesu. Alternativy, např. zpět/vpřed i Cmd+Opt+←/→.
- **Formát souborů** ([format-settings.md](format-settings.md)), **jádro hotové** (`MinorCore`: `FormatSettings`, `FormatDefaults`, `EditorConfig`, `FormatResolver`, `TextFile`):
  - výchozí hodnoty podle standardů (PSR-12, gofmt, Nette, Prettier…), PHP preset `psr12` / `nette`;
  - priority: jazyk < uživatel < projekt < `.editorconfig`; existující soubor si drží konce řádků, odsazení se z něj rozpozná;
  - buffer má vždy jen `\n`, konce řádků, kódování, koncový řádek a ořez mezer se aplikují při uložení;
  - **zbývá do 1e** (vše podle sekce Standardy macOS): `NSDocumentController` (Nedávné, obnova oken), projektové okno se postranním panelem, okno Nastavení, stavový řádek s přepínači (konce řádků, odsazení, kódování) místo menu, okno nastavení v SwiftUI nad stejným `settings.json`, varování před uložením znaků, které kódování neumí, příkaz „Převést odsazení“ (1c), sledování `.editorconfig` a `settings.json` (přenačtení bez restartu).
- **Automatické ukládání**: auto-save při ztrátě fokusu a přepnutí tabu (zapínatelné), **Local History** (snímek při uložení, 14 dní, náhled a obnovení), obnova sezení a obnova po pádu.
- Velké a minifikované soubory (> 5 MB nebo řádek > 10 000 znaků): zjednodušený režim bez zvýraznění a analýzy. Nad 256 MB jen náhled po částech.
- **Binární soubory** (NUL bajty v prvních 8 KB): neotevírat jako text, nabídnout Quick Look nebo hex náhled.
- **Bezpečné ukládání**: atomicky přes dočasný soubor, ale se zachováním **práv** (spustitelné skripty), **vlastníka**, **rozšířených atributů** a **cíle symbolického odkazu** (zapisuje se do cíle, odkaz zůstane). Hotovo: práva a odkazy (oprava z revize plánu).
- **Změna souboru na disku** (git checkout, jiný editor): bez neuložených změn tiše přenačíst se zachováním pozice; s neuloženými změnami lišta „Soubor se změnil na disku: Přenačíst / Porovnat / Ponechat moje“. Smazaný soubor: ponechat obsah a označit.
- **Uvítací okno** („Klonovat z Gitu“ přibude ve 2b.3), **kontrola nástrojů, prostředí z přihlašovacího shellu (D22)**.
- **`.minoride/` v projektu**: `settings.json` (sdílené, commitovat), `local.json` (osobní, do `.gitignore` se přidá automaticky: servery, cesty; v Omezeném režimu se nečte). Hesla nikdy v žádném souboru.
- **Důvěra projektu se ukládá mimo projekt** (`~/Library/Application Support/MinorIDE/trusted.json`, per cesta). V projektu by si ji škodlivý repozitář přinesl sám.

**1f. Dokončení (≈ 3–4 týdny)**
- Zbylé lexery, **zalamování řádků** (mapování řádek ↔ vizuální řádky, vypnuté výchozí, zapnuté pro Markdown), sticky header s aktuální funkcí.
- **Plná přístupnost editoru**: role textové oblasti pro VoiceOver (čtení po znacích, slovech a řádcích, výběr, pozice kurzoru, oznámení změn), Zvýšit kontrast, Omezit pohyb.
- **Systémové textové funkce**, které `NSTextView` dává zadarmo a vlastní view je musí doplnit: Vyhledat (⌃⌘D, silný stisk), menu Služby s výběrem, přetažení textu, sdílená schránka hledání (⌘E), diktování, výběr emoji.
- Hotovo když: VoiceOver přečte a upraví soubor bez myši a každá položka seznamu má test nebo ruční kontrolu v `docs/editor-behaviors.md`.

### Fáze 2: vydávání a vlastní updater (≈ 2 týdny)

**Vydání (GitHub Action `.github/workflows/release.yml`, runner `macos-15`)**
1. Spouští se tagem `vX.Y.Z`.
2. Build Release, `minoride-server` pro `darwin/arm64`, podpis Developer ID s hardened runtime (nejdřív helpery, pak app), notarizace `xcrun notarytool submit --wait`, `xcrun stapler staple`.
3. `MinorIDE-X.Y.Z.zip` (`ditto -c -k --keepParent`) a `.dmg` pro první instalaci.
4. Nahraje zip a dmg jako assety **konceptu** release (draft). Popis release slouží jako release notes.
5. **Podpis lokálně** (`make release-sign`): stáhne zip, ověří notarizaci a Team ID, `tools/signrelease` (Go, stdlib `crypto/ed25519`) vytvoří `MinorIDE-X.Y.Z.zip.sig` klíčem z Klíčenky vývojáře, nahraje ho a release zveřejní. Privátní Ed25519 klíč **není v GitHub Secrets**: kompromitovaný GitHub účet (kde leží certifikát Developer ID) sám aktualizaci nepodepíše.

**Kontrola a instalace v aplikaci (`UpdateKit` + `minoride-updater`)**
- `GET https://api.github.com/repos/novami/minor-ide/releases/latest` s `ETag` (limit 60 dotazů za hodinu bez přihlášení stačí). Pre-release se ignorují. Porovnání semver.
- Nastavení → Aktualizace: **„Automaticky kontrolovat aktualizace“** (výchozí zapnuto), interval denně/týdně, „Přeskočit tuto verzi“. Menu **MinorIDE → Zkontrolovat aktualizace…**
- Při nové verzi okno s release notes (Markdown přes vestavěný `AttributedString(markdown:)`) a tlačítkem **Aktualizovat**.
- Po kliknutí:
  1. stažení s průběhem do `~/Library/Caches/MinorIDE/updates/`;
  2. **ověření Ed25519 podpisu** (CryptoKit, veřejné klíče zabudované v app, podporují rotaci: aktuální + další);
  3. rozbalení `ditto -x -k`;
  4. **ověření code signature** nové app (`SecStaticCodeCheckValidity` s požadavkem na stejné Team ID); verze se čte z `Info.plist` ověřené aplikace (ne z tagu) a starší nebo stejná se odmítne;
  5. nabídnutí uložení neuložených souborů;
  6. kopie `minoride-updater` do tmp a spuštění s PID, cestou staré a nové app; aplikace se ukončí;
  7. updater počká na ukončení, starou app přesune do koše, novou dá na její místo, spustí ji. Při chybě vrátí starou.
- App musí běžet z `/Applications` (jinak ji macOS spouští z izolované kopie). Při startu odjinud nabídnout přesun. Bez práva zápisu do `/Applications` ukázat návod místo pokusu.
- Hotovo když: 0.1.0 se po vydání `v0.1.1` aktualizuje jedním kliknutím; archiv se špatným podpisem nebo cizím Team ID je odmítnut; přerušené stažení nic nerozbije.

### Fáze 2b: denní použitelnost (≈ 4 týdny)

Přesunuto z fází 5 a 7: bez otevření souboru podle jména, hledání, terminálu a Git gutteru se editor denně používat nedá, a na každodenním používání stojí opatření R1.

2b.1 Index cest v paměti + vlastní fuzzy matcher (začátky slov, camelCase, cesta, nedávné soubory výš), **otevření souboru podle jména** (Cmd+Shift+O).
2b.2 **Find in Files** (Cmd+Shift+F) přes `minoride-server search` (RE2, `.gitignore`, paralelně, streamované výsledky), náhled, nahrazení.
2b.3 Gutter změn proti HEAD (vlastní Myers diff nad rope snapshotem), rollback bloku, větev ve stavovém řádku, „Klonovat z Gitu“ v uvítacím okně.
2b.4 Terminál (SwiftTerm) jako spodní panel, víc tabů, start v kořeni projektu, prostředí z přihlašovacího shellu, volba „Bezpečné zadávání z klávesnice“ (jako Terminal.app).
- Hotovo když: v projektu s 20 000 soubory najde soubor do 50 ms od stisku klávesy a Find in Files vrátí první výsledky do 100 ms.

### Fáze 3: LSP klient a Go (≈ 3–4 týdny)

3.1 **LSPKit**: vlastní typy (jen použitá podmnožina), spuštění serveru, `initialize`, inkrementální `didChange` ze snapshotu TextEngine, `didOpen/didClose/didSave`, požadavky serveru na klienta (`client/registerCapability`, `workspace/configuration`, `workspace/applyEdit`, `window/showMessageRequest`), `workspace/didChangeWatchedFiles` z FSEvents (gopls bez něj nepozná `git checkout` ani změnu `go.mod`), `$/progress` ve stavovém řádku, `$/cancelRequest`, restart při pádu (max 3×/min), log v panelu „Language Servers“.
3.2 **Pozice**: vyjednat `positionEncoding: utf-8`, fallback UTF-16 přes převody z rope. Testy s diakritikou a emoji.
3.3 **gopls**: detekce v PATH a `~/go/bin`, nabídka instalace, `staticcheck: true`, `go.work` a víc modulů.
3.4 **Napovídání**: vlastní popup (NSPanel), trigger znaky, Ctrl+Space a ⌥Esc, **lokální fuzzy filtrování** (nový dotaz jen při `isIncomplete`), `completionItem/resolve` pro dokumentaci, snippety s Tab skoky, `additionalTextEdits` (auto-import).
3.5 **Proklik**: **klik kolečkem** (`otherMouseDown`, `buttonNumber == 2`) a **Cmd+klik** → `definition`; podtržení symbolu při držení Cmd; víc cílů → popup; klik na samotnou deklaraci → použití. Cmd+B, Cmd+Opt+B (implementace), Shift+Cmd+B (typ), Opt+F7 (použití do panelu).
3.6 **Historie navigace**: zpět/vpřed (zkratky z keymapy), boční tlačítka myši 3/4, Recent files (⇧⌘E; ⌘E je systémové „Použít výběr pro hledání“).
3.7 Hover, `signatureHelp`, diagnostiky (vlnovky, gutter, scrollbar, panel Problems, F2/Shift+F2), quick-fixy Opt+Enter, rename Shift+F6 s náhledem, formátování Cmd+Opt+L a při uložení, semantic tokens přes lexer.
3.8 **Externí LSP servery (D23)**: `settings.json` mapuje jazyk na příkaz a argumenty (např. `typescript-language-server --stdio`); stejný klient, stejné funkce 3.4–3.7 podle schopností serveru. V Omezeném režimu se nespouští.
- Hotovo když: reálný Go projekt má všechno z 3.4–3.7, latence klávesy beze změny, pád gopls editor přežije a TypeScript soubor má napovídání přes externí server.

### Fáze 4: PHP jazykový server (≈ 14–20 týdnů)

**Markerové testy od prvního dne** (`server/testdata/php/`):

```php
$user = new User();
$user->/*|complete: getName, getEmail*/;
$x = $user->getName/*|def: User.php:12*/();
```

**4a. Lexer a parser PHP 7.2 až aktuální (≈ 5–7 týdnů)**
- **Nová verze PHP je opakovaný úkol**: po každém vydání (ročně v listopadu) projít RFC, doplnit lexer, parser, stuby a fixture. Lexer v Go a zvýrazňovací lexer ve Swiftu sdílí **jeden korpus golden testů tokenů**, aby se nerozešly.
- Lexer: všechny tokeny včetně inline HTML, `<?=`, heredoc/nowdoc s interpolací, `?->`, atributy `#[`, `match`, enumy, `readonly`, property hooks a asymetrická viditelnost (8.4), operátor `|>` a `clone` s argumenty (8.5), pojmenované argumenty, first-class callable `f(...)`, číselné oddělovače.
- Parser: rekurzivní sestup pro příkazy, Pratt pro výrazy s precedencí PHP. AST s bajtovými pozicemi a komentáři navázanými na uzly (PHPDoc).
- **Zotavení z chyb**: neočekávaný token → uzel `Missing`, synchronizace na `;`, `}` nebo klíčové slovo příkazu. Nikdy panic, vždy strom + seznam chyb. Klíčové pro napovídání v rozepsaném kódu (`$user->` na konci řádku).
- Parser přijímá nadmnožinu syntaxe. Chyby podle verze PHP projektu hlásí samostatná kontrola.
- Celý soubor se po změně parsuje znovu (běžný soubor < 2 ms). Inkrementální parsování jen pokud to měření ukáže jako nutné.
- Testy: korpus `Zend/tests` z php-src a `vendor/` velkých projektů (0 panic, platné soubory bez chyb), **Go fuzzing** (`go test -fuzz`), golden testy AST.
- PHPDoc parser: `@var @param @return @throws @template(-covariant) @extends @implements @method @property(-read/-write) @mixin @deprecated`, typy včetně generik, `array{shape}`, `list<T>`, `class-string<T>`. Stejně se čtou varianty s předponou `@phpstan-` a `@psalm-` (mají přednost) a celá gramatika typů PHPStanu (`int<0, max>`, `non-empty-string`, `key-of<T>`, `value-of<T>`, `callable(int): string`, podmíněné typy, `@phpstan-type` aliasy, `@phpstan-assert`). Typ, kterému inference nerozumí, se **přečte bez chyby a počítá se jako `mixed`**.

**4b. Index (≈ 2–3 týdny)**
- Zdroje: projekt; `vendor/` podle Composeru (`installed.json`, `autoload_psr4.php`, `autoload_classmap.php`); stuby PHP (Q2) filtrované podle verze PHP projektu.
- Deklarace s FQN, umístěním, signaturou a PHPDoc; rozlišení jmen (namespace, `use` všech druhů, aliasy, `self/static/parent`, fallback globálních funkcí); hierarchie a podtypy; **traity** (`use`, `insteadof`, `as`, abstraktní a statické členy), konstanty rozhraní, metody enumů.
- **Cache na disku** (`~/Library/Caches/MinorIDE/phpls/<hash>/`, gob, per soubor hash obsahu), přeindexování jen změněných souborů, `didChangeWatchedFiles`, změna `composer.lock` → přeindexovat `vendor/`.
- Paralelní indexace, průběh přes `$/progress`, odpovídá i během indexace.
- LSP: `documentSymbol`, `workspace/symbol`, `definition` jmen, `foldingRange`, syntaktické chyby.

**4c. Typová inference a napovídání (≈ 3–4 týdny)**
- Typy: skaláry, `mixed`, `null`, nullable, union, intersection, třídy, `array<K,V>`, `list<T>`, shapes, `iterable<T>`, `callable`, `static/self/$this`, generika `@template` (třídy i metody), `class-string<T>`.
- Inference (líně, memoizace per verze souboru): nativní typy, PHPDoc, přiřazení, `new`, řetězení volání, narrowing (`instanceof`, `is_*`, `!== null`, early return), `foreach`, closure a arrow funkce, inline `@var`, destrukce, ternár, `??`, `match`.
- Magie: `__get/__call/__callStatic` přes `@property/@method`, `@mixin`, Nette SmartObject. Tovární metody a kontejnery se typují přes generika a podmíněné typy z PHPDoc (4a), ne přes formáty jiných IDE.
- Scope proměnných: parametry, přiřazení před kurzorem, `use (...)`, `global`, `static`.
- LSP: **`completion`** (členy za `->`, `?->`, `::`; třídy, funkce, konstanty s **auto-importem**; proměnné; klíčová slova; pojmenované argumenty), **řazení** podle očekávaného typu, blízkosti scope a nedávného použití; `definition` členů, `typeDefinition`, `implementation`, `hover`, `signatureHelp`.
- Hotovo když: markerové testy pokrývají každý bod a v reálném Nette projektu funguje napovídání a proklik kolečkem na řetězená volání.

**4d. Použití, přejmenování, inspekce (≈ 2–3 týdny)**
- `references`: kandidáti z invertovaného indexu jmen, ověření inferencí, streamované výsledky.
- `rename`: třídy (včetně souboru podle PSR-4), metody, vlastnosti, proměnné, konstanty; ne symboly z `vendor/`.
- Inspekce při psaní: neznámá třída/funkce/metoda/vlastnost, nepoužitý `use` a proměnná, počet argumentů, volání na možném `null`, syntaxe mimo verzi PHP projektu, přístup k private/protected. **Inspekce hlásí jen to, co je jisté**: na `mixed` nebo nerozpoznaném typu mlčí. Falešná chyba škodí důvěře víc než chybějící; hloubku dodá PHPStan.
- Quick-fixy: import třídy, odstranit nepoužité `use`, implementovat metody rozhraní, vytvořit metodu/vlastnost, doplnit PHPDoc.

**4e. PHPStan, formátování, Docker (≈ 1 týden, `AnalysisKit`)**
- `phpstan analyse --error-format=json --no-progress <soubor>` při uložení (debounce 300 ms, rušení běžícího), `phpstan.neon(.dist)` projektu, sloučení s diagnostikami phpls bez duplicit, „Analyzovat celý projekt“.
- PHP CS Fixer / PHP_CodeSniffer z `vendor/bin`.
- **PHP v Dockeru**: „spouštět PHP nástroje přes“ lokálně / `docker compose exec <služba>` s mapováním cest.

### Fáze 5: navigace podle symbolů (≈ 1 týden)

Index cest, otevření souboru a Find in Files jsou ve fázi 2b.

5.1 **Search Everywhere** (dvojité Shift): soubory (index z 2b.1), symboly z gopls i phpls, akce IDE. Cmd+Opt+O symbol.
5.2 Struktura souboru (Cmd+F12) a breadcrumbs.
- Hotovo když: Search Everywhere vrátí symbol v projektu s 20 000 soubory do 100 ms.

### Fáze 6: DB klient (≈ 4 týdny)

6.1 **`minoride-server db`**
- Ovladače `go-sql-driver/mysql`, `pgx/v5`, vlastní cgo binding na systémovou `libsqlite3`.
- Metody `connect`, `disconnect`, `listDatabases`, `listSchemas`, `listTables`, `describeTable` (sloupce, indexy, FK, DDL), `query` (stream po stránkách), `fetchMore`, `cancel` (přes `context`), `execute`, `beginTx/commit/rollback`.
- **SSH tunel přes systémové `ssh -W host:port`** (respektuje `~/.ssh/config`, ProxyJump, ssh-agent): stdin/stdout procesu slouží jako spojení ovladače (`RegisterDialContext` u MySQL, `DialFunc` u pgx). Žádný lokální port, na který by se mohl připojit jiný proces. Hlídání a ukončení procesu. Jakmile vznikne SSH vrstva 6b.1, jede přes sdílené spojení `ControlMaster`.
- Bezztrátové typy: NULL, binární jako base64, velká čísla jako string, datum ISO 8601.
- Integrační testy proti Docker Compose (MariaDB 11, PostgreSQL 17), build tag `integration`.
6.2 Připojení: dialog (host, port, uživatel, DB, SSH, TLS), „Test připojení“, `.minoride/datasources.json` nebo globálně, **hesla jen v Keychain**.
6.3 Prohlížeč schématu (lazy strom, obnovení).
6.4 Data grid: NSTableView (view-based), stránkování po 500, řazení, filtr, NULL, JSON/BLOB prohlížeč, kopírování jako TSV/CSV/INSERT.
6.5 Editace dat: lokální změny, „Submit“ s **náhledem SQL**, transakce, jen tabulky s PK.
6.6 SQL konzole: vlastní SQL lexer, Cmd+Enter spustí výraz pod kurzorem, výsledky v tabech, historie, napovídání tabulek a sloupců z cache schématu.
6.7 Export do CSV/JSON.
6.8 **Bezpečnost dat**: příznak „produkce“ (červený pruh, výchozí jen pro čtení), potvrzení `UPDATE`/`DELETE` bez `WHERE` a `DROP`/`TRUNCATE`, časový limit dotazu, limit řádků. Historie dotazů lokálně a vypnutelná (může obsahovat citlivá data). Heslo jde do helperu přes stdin (JSON-RPC), nikdy přes argumenty nebo proměnné prostředí (viditelné v `ps`). TLS u MySQL/PostgreSQL s ověřením certifikátu, volitelně vlastní CA.
- Hotovo když: připojení k MariaDB přímo i přes SSH, editace dat s náhledem SQL a zrušení 30s dotazu fungují.

### Fáze 6b: Vzdálené servery: SSH, SFTP, FTPS, rsync, nasazování (≈ 5–6 týdnů)

Sdílí SSH vrstvu s DB tunelem (6.1) a terminálem (2b.4).

6b.1 **SSH vrstva (`minoride-server remote`)**
- Jedno spojení na server pro všechno (SFTP, terminál, tunely, rsync, DB): `ssh -o ControlMaster=auto -o ControlPath=~/.minoride/s/%C -o ControlPersist=10m`, adresář s právy `0700`. Cesta musí být **krátká**: unixový socket má limit 104 bajtů a ssh si při zakládání přidává 17 znaků, takže `~/Library/Caches/…` by u delšího uživatelského jména selhalo. Test s 32znakovým jménem domovské složky.
- Autentizace jen tím, co umí OpenSSH: klíče, ssh-agent (včetně 1Password a Secretive), certifikáty, `~/.ssh/config` (aliasy, ProxyJump). Heslo nebo passphrase přes vlastní `SSH_ASKPASS` helper (`SSH_ASKPASS_REQUIRE=force`), který si je vyžádá od IDE (Klíčenka nebo dotaz); **heslo nikdy v argumentech ani v proměnných prostředí**.
- **Askpass ↔ IDE**: unixový socket v adresáři `0700`, který IDE založí pro jedno spuštění ssh; askpass dostane cestu a jednorázový token v prostředí (token není heslo a po použití neplatí). IDE ověří token a UID protistrany (`LOCAL_PEERCRED`). Stejně funguje `GIT_ASKPASS` (7.5).
- **Klíč serveru**: první připojení ukáže otisk (SHA256) a uloží ho do `~/.ssh/known_hosts` až po potvrzení; nesouhlasící klíč = tvrdá chyba s vysvětlením, žádné „pokračovat i tak“.
- Správce tunelů: seznam aktivních přesměrování portů, start/stop.

6b.2 **SFTP klient (vlastní, protokol v3, Go)** nad `ssh -s sftp`: list, stat, read/write po blocích s pipeliningem (víc požadavků za sebou, rychlost blízko `scp`), rename, mkdir, remove, setstat (práva), symlinky. Testy proti OpenSSH v Dockeru.

6b.3 **FTPS klient (vlastní, Go, `crypto/tls`)**: explicitní TLS (`AUTH TLS`), pasivní režim (`EPSV`/`PASV`), `MLSD` s fallbackem na `LIST`, TLS i na datovém kanálu (`PROT P`) **s obnovením TLS relace řídicího spojení** (sdílená `ClientSessionCache`; vsftpd a ProFTPD to ve výchozím nastavení vyžadují, test s `require_ssl_reuse=YES` na TLS 1.2 i 1.3), ověření certifikátu (výjimka jen ručně pro konkrétní otisk, uložená). Nešifrované FTP se nepodporuje.

6b.4 **Servery a mapování**: dialog serveru (typ SFTP/FTPS, host, port, uživatel, kořenová složka, příznak produkce), mapování lokální ↔ vzdálená cesta, vyloučené cesty (výchozí `.git`, `.minoride/local.json`, `node_modules`, `.env*`). Uloženo v `.minoride/local.json`, heslo v Klíčence.

6b.5 **Vzdálený prohlížeč**: panel jako Finder (strom, ikony, velikost, datum, práva), drag & drop z/do Finderu i stromu projektu, otevřít vzdálený soubor přímo (stáhne se do cache, uložení nahraje zpět), **detekce konfliktu** (soubor se na serveru změnil od stažení → porovnat / přepsat / zrušit).

6b.6 **Nasazování**
- Nahrát / stáhnout soubor či složku (kontextové menu, zkratky), **nahrávání při uložení** (výchozí vypnuto; u produkce zakázané bez potvrzení).
- **Porovnat se serverem**: diff lokální vs. vzdálený soubor, a pro složku seznam rozdílů.
- **Synchronizace přes rsync** (jen SFTP servery): vždy nejdřív náhled (`--dry-run --itemize-changes`) v tabulce *nahrát / smazat / změnit*, mazání (`--delete`) jen po výslovném zaškrtnutí, vylučovací pravidla z mapování, průběh a zrušení. U FTPS synchronizace vlastním porovnáním velikostí a časů.
- Fronta přenosů s průběhem, opakováním a zrušením; souběžně max. 4 přenosy na server.

6b.7 **Vychytávky**: vzdálený terminál jedním klikem (SwiftTerm + `ssh` přes sdílené spojení), „Otevřít vzdálenou složku“ (SFTP bez lokální kopie, inteligence jen syntaktická), zobrazení logu na serveru živě (`tail -f`), rychlé zkopírování cesty/URL souboru na serveru, přenos práv souborů (chmod v dialogu), záložky oblíbených vzdálených složek.
- Hotovo když: projekt se nasadí na SFTP i FTPS server, rsync náhled odpovídá skutečnosti, změna klíče serveru je odmítnuta a v `ps` ani logu se neobjeví heslo.

### Fáze 7: Git (≈ 4 týdny)

Gutter změn a terminál jsou ve fázi 2b.

7.1 Panel změn, side-by-side diff, commit s výběrem souborů **i jednotlivých bloků**, amend.
7.2 Blame v gutteru, přepínání větví, pull/push s výstupem, stash.
7.3 **Řešení konfliktů**: třísloupcové sloučení (moje / výsledek / jejich) s přijetím bloků z obou stran, seznam konfliktních souborů při merge a rebase.
7.4 Log: historie větve a souboru, diff commitu.
7.5 Přihlašování Git: systémový `git credential-osxkeychain` a ssh-agent, vlastní GUI `GIT_ASKPASS` pro passphrase; IDE si Git hesla neukládá samo.
- Hotovo když: merge s konfliktem ve dvou souborech se dá vyřešit a commitnout bez terminálu.

### Fáze 7b: spouštění, testy a debugger (≈ 5–6 týdnů)

7b.1 **Run konfigurace** (`RunKit`): příkaz jako pole argumentů, pracovní složka, prostředí; uložené v `.minoride/settings.json`. Výstup v panelu, proklik z `cesta:řádek` ve výstupu.
7b.2 **Test runner**: `go test -json`, PHPUnit (JUnit XML), Nette Tester; strom výsledků, ikona v gutteru u testu (spustit / ladit), opakování neúspěšných, proklik z chyby na řádek.
7b.3 **DAP klient** (vlastní typy, jen použitá podmnožina): breakpointy v gutteru přes kotvy (i podmíněné), zásobník, proměnné, sledované výrazy, krokování, vyhodnocení výrazu, hodnota při najetí myší.
7b.4 **Go**: `dlv dap` na `127.0.0.1` s náhodným portem; ladění programu i testu.
7b.5 **PHP**: `minoride-server debug` je adaptér Xdebug **DBGp → DAP** (aplikace mluví jen DAP přes stdio). Naslouchá na `127.0.0.1:9003` (nastavitelné) jen po dobu ladicí relace; mapování cest pro Docker sdílené s 4e; ladění CLI skriptu, testu i webového požadavku.
7b.6 **Spike před 7b.5**: ověřit, že Xdebug z kontejneru (`host.docker.internal`) dosáhne na port vázaný na `127.0.0.1`. Pokud ne, zastavit a popsat varianty.
- Hotovo když: breakpoint v Go testu i v Nette presenteru (lokálně i v Dockeru) zastaví, jdou číst proměnné a krokovat, a po skončení relace nezůstane otevřený žádný port (test).

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
SQL v PHP řetězcích, pokrytí testů (coverage), golangci-lint, inlay hinty, live templates, refaktoringy extract/inline.

---

## Bezpečnost

### Model hrozeb (před čím chráníme)

| Hrozba | Příklad | Ochrana |
|---|---|---|
| Únik uložených hesel | malware čte soubory v `~/Library` | hesla **jen v Klíčence** (souborová přihlašovací klíčenka, bez iCloudu, D19), v souborech jen odkaz (id položky); položky přístupné jen podepsané aplikaci (ACL Klíčenky váže podpis Developer ID) |
| Heslo viditelné jiným procesům | `ps aux`, `/proc`, výpisy prostředí | hesla do helperů jen přes stdin/JSON-RPC nebo `SSH_ASKPASS`, nikdy argumenty ani proměnné prostředí |
| Heslo v logu nebo schránce | ladicí log, zkopírované heslo | `os.Logger` s `privacy: .private`, žádné logování parametrů připojení; zkopírované heslo se ze schránky smaže po 60 s a označí jako `org.nspasteboard.ConcealedType` |
| Útočník uprostřed (MITM) | podvržený SSH server, falešný TLS certifikát | `known_hosts` s potvrzením otisku, odmítnutí změněného klíče; TLS vždy s ověřením certifikátu; FTP bez šifrování nepodporované |
| Škodlivý projekt | `phpstan.neon` s bootstrapem, `.minoride/settings.json` s příkazem Dockeru, Composer skripty | **Omezený režim (D18)**: dokud projekt není důvěryhodný, nespouští se žádný nástroj ani příkaz z nastavení projektu; vlastní parsery běží (nespouští kód). Důvěra se pamatuje per cesta v `~/Library/Application Support/MinorIDE/trusted.json`, nikdy v projektu; `.minoride/local.json` se v Omezeném režimu nečte |
| Kód v konfiguraci repozitáře | `.git/config` s `core.fsmonitor` nebo `core.pager` ve stažené složce, `go.mod` s jiným toolchainem | v Omezeném režimu se nespouští `git`, gopls, externí LSP servery, Docker, run konfigurace ani debugger (D18) |
| Podvržená aktualizace | kompromitovaný GitHub účet | dvojí ověření ze **dvou oddělených míst**: Ed25519 klíč jen lokálně u vývojáře, certifikát Developer ID v CI; ochrana proti downgradu podle verze v `Info.plist` ověřené aplikace |
| Kompromitovaná závislost | škodlivá nová verze knihovny | závislosti připnuté (`go.sum`, přesná verze SwiftTerm, připnutá verze stubů PHP), `govulncheck` v CI, GitHub Actions připnuté na SHA, aktualizace závislostí jen ručně s kontrolou změn |
| Lokální síťový útok na helpery | jiný proces se připojí na port | helpery komunikují **jen přes stdin/stdout**, nikdy neotevírají síťový port; LSP servery také přes stdio; DB tunel přes `ssh -W` bez lokálního portu. Výjimky jen podle D24: ladění (`127.0.0.1`, jen během relace) a askpass (unixový socket `0700` + jednorázový token + kontrola UID) |
| Ztráta dat | pád při ukládání, rsync `--delete` | atomické ukládání, Local History, náhled před každou destruktivní operací, mazání do Koše |

### Pravidla pro kód
- Žádné tajemství v repozitáři, logu, crash reportu, `settings.json`, `local.json` ani v historii SQL dotazů (u připojovacích řetězců se heslo vymaže).
- Každý spouštěný proces přes `Process` s polem argumentů, **nikdy přes shell s poskládaným řetězcem** (injection). Výjimka jen pro načtení PATH (D22), bez uživatelských dat.
- Cesty ze serveru a z projektu se před použitím normalizují; žádný zápis mimo cílovou složku (ochrana proti `../` ve jménech ze serveru).
- Hardened runtime bez výjimek (`disable-library-validation`, `allow-jit` a podobné zakázané).
- Bezpečnostní testy: heslo se neobjeví v `ps` během připojení (test spustí připojení a čte tabulku procesů), změněný klíč serveru je odmítnut, Omezený režim nespustí PHPStan ani `git` (repozitář s `core.fsmonitor` v `.git/config` nic nespustí), projekt s vlastním `.minoride/local.json` se neotevře jako důvěryhodný, po ladění nezůstane otevřený port.

## 3. Rizika

| # | Riziko | Dopad | Opatření |
|---|---|---|---|
| R1 | Vlastní editor má stovky drobných chování (IME, selekce, undo, scroll), kde chyby hned bolí | vysoký | TextEngine bez AppKit s property-based testy, checklist `editor-behaviors.md`, každodenní používání od fáze 2 |
| R2 | Vlastní PHP parser: správnost napříč PHP 7.2 až aktuální, každý rok nová verze | vysoký | korpus php-src + vendor, fuzzing, golden testy, parser nikdy nepanikaří |
| R3 | Vlastní PHP server je nejrizikovější část rozsahem | vysoký | podfáze 4a–4e, každá použitelná; PHPStan kryje hlubokou analýzu |
| R4 | PHP napovídání až po 4c (≈ 10 měsíců od začátku) | střední | pořadí drží editor a Go použitelné dřív; fáze 2b dává denní použitelnost už po ≈ 5 měsících |
| R5 | Regrese plynulosti | vysoký | výkonové testy psaní a scrollu v CI, build selže při překročení rozpočtu |
| R6 | Řazení napovídání (IDE působí „chytře“ hlavně díky němu) | střední | řazení podle typu, scope a nedávného použití; testy pořadí top 3 |
| R7 | Chyba vlastního updateru rozbije instalaci | vysoký | dvojí ověření (Ed25519 + code signature), atomická výměna s návratem, test přerušeného stažení |
| R8 | Únik Ed25519 klíče nebo certifikátu Developer ID | vysoký | Ed25519 klíč jen v Klíčence vývojáře (ne na GitHubu), certifikát Developer ID v GitHub Secrets, offline záloha, rotace klíče (app zná aktuální i další), postup v `docs/release.md` |
| R9 | gopls na velkých monorepech 1–2 GB RAM | střední | `directoryFilters`, varování v UI |
| R10 | Celkový rozsah 18–23 měsíců | vysoký | striktně po fázích, vydávat a používat průběžně; kandidáti na odložení za MVP, když se čas natáhne: 6b (FTPS, rsync), 7.3–7.4, 8.7 |
| R11 | Únik hesla (DB, SSH, FTPS) | vysoký | sekce Bezpečnost: Klíčenka, žádná hesla v argumentech, logu ani souborech, bezpečnostní testy |
| R12 | Škodlivý projekt spustí kód přes nástroje | vysoký | Omezený režim (D18) |
| R13 | Klíčenka se při vývoji ptá po každém buildu (ad-hoc podpis mění identitu) | nízký | vývojové buildy podepisovat stálým vývojovým certifikátem; testy Klíčenky s vlastní testovací klíčenkou |
| R14 | `openrsync` v macOS neumí všechny přepínače rsync 3.x | střední | používat jen společnou podmnožinu přepínačů, rsync 3.x z Homebrew využít, když je |
| R15 | FTPS servery na hostinzích se liší (pasivní režim za NAT, starý TLS) | střední | testy proti `vsftpd` a `pure-ftpd` v Dockeru, TLS 1.2+ povinně, obnovení TLS relace na datovém kanálu, srozumitelné chyby |
| R16 | Dva PHP lexery (Swift pro zvýraznění, Go pro parser) se rozejdou | střední | společný korpus golden testů tokenů, nová syntaxe vždy do obou ve stejném commitu |
| R17 | Falešné chyby inspekcí phpls u typů, kterým inference nerozumí | vysoký | neznámý typ = `mixed`, inspekce jen při jistotě, korpus reálných projektů musí projít bez hlášení „neznámá metoda“ |
| R18 | Xdebug z Dockeru nedosáhne na port vázaný na `127.0.0.1` | střední | spike 7b.6 před implementací, varianty až podle výsledku |

## 4. Otevřené otázky

- **Q1** Testovací projekty: zatím veřejné open-source (Nette `web-project`, Laravel, velké Go repo), vlastní doplnit později.
- **Q2** Zdroj stubů PHP (signatury vestavěných funkcí a rozšíření). Původně plánovaná sada je dílo výrobce konkurenčního IDE, nese jeho jméno v názvu, v atributech i v povinném poděkování, proto vypadla. Doporučení: **oficiální `*.stub.php` ze zdrojů PHP** (součást php-src od PHP 8.0, jádro a přibalená rozšíření) a stuby z repozitářů PECL rozšíření (redis, imagick, xdebug…); dostupnost funkcí ve verzích 7.2–7.4 doplnit vlastní tabulkou. Čeká na souhlas uživatele (nová datová závislost).

---

## 5. Pravidla pro implementátora (Sonnet)

Po založení repozitáře zkopírovat do `CLAUDE.md` projektu.

- Pracuj po úkolech v pořadí fází. Úkol končí splněním **Hotovo když**, testem hlavní cesty a commitem.
- **Žádná vazba na konkurenční IDE**: nejmenovat je v UI, kódu, dokumentaci ani commitech a nepodporovat jejich vlastní formáty souborů ani jejich data.
- Commity malé, jen vlastní soubory (`git commit -- <soubory>`), bez AI podpisů. Nikdy `git push` bez vyžádání.
- **Žádná nová závislost bez souhlasu uživatele.** Povolené jsou jen: SwiftTerm, `go-sql-driver/mysql` (MPL-2.0), `jackc/pgx/v5` (a jejich závislosti), `golang.org/x/*`. Zdroj stubů PHP čeká na rozhodnutí (Q2). Systémové frameworky macOS a stdlib Go jsou volné. Licence každé závislosti patří do okna Poděkování.
- **Bezpečnost podle sekce Bezpečnost**: hesla jen v Klíčence, nikdy v argumentech procesů, proměnných prostředí, logu ani souborech; procesy jen s polem argumentů, ne přes shell; respektovat Omezený režim (i pro Git, gopls a debugger); helpery jen přes stdin/stdout, porty jen podle D24.
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
│                               TerminalKit, RunKit, UpdateKit, SecretsKit, RemoteKit)
├─ Tests/                      (<Modul>Tests)
├─ server/                     (Go: minoride-server)
├─ tools/                      (bundle.sh, signrelease/)
├─ Resources/                  (Info.plist, ikony, témata, php-stubs)
├─ docs/                       (ANALYSIS, PLAN, DEPENDENCIES, STATUS, keymap, editor-behaviors, release, spike-*,
│                               security: postupy rotace klíčů, hlášení zranitelností)
└─ .github/workflows/          (ci.yml, release.yml)
```
