# Analýza: GoLand, PhpStorm, VS Code (a Zed jako reference rychlosti)

Cíl: zjistit, co dělá tyto IDE užitečnými, jak fungují uvnitř, a co z toho převzít do vlastního rychlého IDE pro Go a PHP na Apple Silicon.

## 1. Jak fungují uvnitř

### JetBrains (GoLand, PhpStorm), IntelliJ Platform
- **Běží na JVM** (Kotlin/Java, vlastní UI toolkit nad Swingem). Proto startují pomalu a berou 1–3 GB RAM.
- **VFS** (virtuální souborový systém): snapshot disku, který sleduje změny přes nativní file watcher.
- **PSI** (Program Structure Interface): plný syntaktický strom s odkazy (reference) pro každý jazyk. Nad ním stojí všechno: napovídání, navigace, refaktoring i inspekce.
- **Stub indexy**: na disk se ukládá zkrácená struktura (třídy, metody, signatury) celého projektu i `vendor/`. Díky tomu je proklik okamžitý i v obřím projektu. Za to se platí počátečním „Indexing…“.
- **Typová inference** pro PHP: čte PHPDoc (`@var`, `@return`, `@template`), generiky, `instanceof` narrowing a metadata frameworků (`.phpstorm.meta.php`). Tady je jejich hlavní náskok.
- **Inspekce**: stovky pravidel nad PSI s quick-fixy (Alt+Enter). Externí nástroje (PHPStan, Psalm, PHP_CodeSniffer, golangci-lint) se do editoru zapojují jako další zdroj inspekcí.
- **Jazyk Go v GoLandu** má vlastní implementaci analýzy, ne gopls.

### VS Code
- **Electron** (Chromium + Node.js), editor je Monaco.
- **Text buffer** je „piece tree“, který zvládá velké soubory s levnou editací.
- **Syntax**: TextMate gramatiky (regexy) plus postupně tree-sitter.
- **Inteligence je mimo editor** v jazykových serverech přes **LSP** (Language Server Protocol, JSON-RPC přes stdio). Debugování přes **DAP** (Debug Adapter Protocol). Rozšíření běží v samostatném „extension host“ procesu, takže pomalé rozšíření nezamrazí UI.
- Go: oficiální rozšíření používá **gopls** (od týmu Go), kvalita je velmi blízko GoLandu.
- PHP: **Intelephense** (Node, část funkcí placená) nebo **Phpactor** (PHP, open source). Kvalita je znatelně pod PhpStormem.

### Zed (reference pro rychlost)
- Rust a vlastní GPU UI framework (GPUI nad Metalem), text buffer je rope (B-strom), syntax přes tree-sitter, inteligence přes LSP.
- Ukazuje, že **LSP architektura + nativní UI = svižnost**. Pomalost VS Code jde hlavně za Electronem, ne za LSP.

## 2. Co tyto IDE umí (funkční mapa)

Priorita: **M** = MVP, **P** = později, **N** = zatím ne.

| Oblast | Funkce | GoLand | PhpStorm | VS Code | Priorita | Jak u nás |
|---|---|---|---|---|---|---|
| Editor | Zvýraznění syntaxe, folding, závorky | ✔ | ✔ | ✔ | M | vlastní lexer |
| | Multi-cursor, sloupcový výběr | ✔ | ✔ | ✔ | M | editor komponenta |
| | Hledat/nahradit, regex | ✔ | ✔ | ✔ | M | vlastní |
| | Live templates / snippety, postfix | ✔ | ✔ | ✔ | P | LSP snippety + vlastní |
| Napovídání | Kontextové doplňování | ✔ | ✔ | ✔ | **M** | LSP `completion` |
| | Auto-import (use / import) | ✔ | ✔ | ✔ | M | LSP `additionalTextEdits` |
| | Nápověda parametrů, hover s dokumentací | ✔ | ✔ | ✔ | M | LSP `signatureHelp`, `hover` |
| | Inlay hinty (názvy parametrů) | ✔ | ✔ | ✔ | P | LSP `inlayHint` |
| Navigace | Proklik na deklaraci (Cmd+klik, **klik kolečkem**) | ✔ | ✔ | ✔ | **M** | LSP `definition` |
| | Implementace, typ, použití (usages) | ✔ | ✔ | ✔ | M | LSP `implementation`, `typeDefinition`, `references` |
| | Zpět/vpřed v historii navigace | ✔ | ✔ | ✔ | **M** | vlastní historie |
| | Search Everywhere (Shift Shift), soubor, symbol | ✔ | ✔ | ✔ | M | vlastní index + LSP `workspace/symbol` |
| | Struktura souboru (Cmd+F12) | ✔ | ✔ | ✔ | M | LSP `documentSymbol` |
| | Hledání v souborech | ✔ | ✔ | ✔ | M | ripgrep |
| Analýza | Chyby a varování v editoru | ✔ | ✔ | ✔ | **M** | LSP diagnostiky |
| | PHPStan / Psalm | ✔ | ✔ | rozšíření | **M** | PHPStan jako proces |
| | staticcheck / go vet / golangci-lint | ✔ | — | ✔ | M | gopls (staticcheck), golangci-lint P |
| | Quick-fixy (Alt+Enter) | ✔ | ✔ | ✔ | M | LSP `codeAction` |
| Refaktoring | Přejmenování | ✔ | ✔ | ✔ | M | LSP `rename` |
| | Extract/inline/change signature | ✔ | ✔ | částečně | P | LSP code actions (gopls umí extract) |
| Formátování | gofmt/goimports, PHP CS Fixer | ✔ | ✔ | ✔ | M | LSP `formatting` + externí nástroj |
| Databáze | Připojení, prohlížeč schématu, data grid, SQL konzole | ✔ (DataGrip) | ✔ (DataGrip) | rozšíření | **M** | Go sidecar proces |
| | SQL v PHP řetězcích (language injection) | ✔ | ✔ | — | P | vnořený SQL lexer + schéma |
| Spouštění | Run konfigurace, testy, coverage | ✔ | ✔ | ✔ | P | `go test -json`, PHPUnit |
| Debug | Delve / Xdebug | ✔ | ✔ | ✔ | P | DAP (`dlv dap`, vscode-php-debug) |
| VCS | Git gutter, diff, commit, blame | ✔ | ✔ | ✔ | M | `git` CLI |
| Terminál | Vestavěný terminál | ✔ | ✔ | ✔ | M | SwiftTerm |
| Frameworky | Laravel/Symfony; Nette přes plugin | — | ✔ | rozšíření | **M** | Nette/Latte/NEON ve vlastním PHP serveru |
| Ostatní | HTTP klient, Docker, remote dev, AI | ✔ | ✔ | ✔ | N | — |

## 3. Co z toho plyne pro náš návrh

1. **Go: nepsat od nuly**, gopls je špičkový. **PHP: vlastní jazykový server** (rozhodnutí uživatele). Existující PHP servery (Phpactor, Intelephense) jsou pod úrovní PhpStormu a nedají se dobře rozšířit o Nette/Latte. Vlastní server znamená nejvíc práce v celém projektu, ale je to jediná cesta k PhpStorm kvalitě. Hlubokou analýzu dál dodá PHPStan.
2. **Svižnost dělá UI vrstva, ne LSP.** Nativní Swift/AppKit editor, žádné Electron/WebView v editační cestě. Všechna práce s LSP a DB asynchronně mimo hlavní vlákno.
3. **Izolace procesů jako ve VS Code**: jazykové servery, PHPStan i DB ovladače běží v samostatných procesech. Pád nebo zaseknutí nezamrazí editor.
4. **Detaily, které dělají PhpStorm „PhpStormem“**, a stojí za to je okopírovat:
   - klik kolečkem = přejít na deklaraci; Cmd+klik na samotnou deklaraci = ukázat použití;
   - podtržení symbolu při držení Cmd (hover s náhledem);
   - zpět/vpřed (Cmd+[ / Cmd+]) i boční tlačítka myši;
   - Search Everywhere přes dvojité Shift;
   - napovídání bez latence: filtrovat lokálně během psaní a nepočkat na server u každé klávesy;
   - DB grid s editací buněk a náhledem SQL před odesláním.
5. **Kde zůstaneme za PhpStormem**: hluboká typová inference PHP (generiky, framework magie), pokročilé refaktoringy, stovky vlastních inspekcí. To je vědomý kompromis.
