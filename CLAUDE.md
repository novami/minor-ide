# MinorIDE

Nativní IDE pro Go a PHP na macOS (Apple Silicon). Plán: `docs/PLAN.md`, závislosti: `docs/ZAVISLOSTI.md`.

## Příkazy
- `make test` – Go vet + testy, Swift testy (vždy přes make: SwiftPM s Command Line Tools potřebuje native build system a cesty k Swift Testing)
- `make bench` – výkonový benchmark editoru (release)
- `make bundle` / `make run` – sestaví a spustí `build/MinorIDE.app`
- `make server` – Go helper `server/bin/minoride-server`
- `make l10n` – vygeneruje angličtinu z `L("…")` a doplní nové texty do překladů; `make l10n-new LANG=de` přidá jazyk

## Pravidla
- Pracuj po úkolech v pořadí fází z `docs/PLAN.md`. Úkol končí splněním „Hotovo když“, testem hlavní cesty a commitem.
- Commity malé, jen vlastní soubory (`git commit -- <soubory>`), bez AI podpisů. Nikdy `git push` bez vyžádání.
- **Žádná nová závislost bez souhlasu uživatele.** Povolené: SwiftTerm, `go-sql-driver/mysql`, `jackc/pgx/v5` (+ jejich závislosti), `golang.org/x/*`, phpstorm-stubs (data). Systémové frameworky macOS a stdlib Go jsou volné.
- Na hlavním vlákně jen UI. Změna v editační cestě musí projít `make bench` v rozpočtu z plánu.
- `TextEngine`, `Highlight`, `LSPKit`, `MinorCore` nesmí importovat AppKit.
- phpls: každá nová schopnost začíná markerovým testem; každá opravená chyba parseru dostane fixture.
- **UI podle Apple HIG** (sekce „Standardy macOS“ v `docs/PLAN.md`): standardní lišta menu a zkratky, sheety místo modálních dialogů, okno Nastavení (⌘,), systémové barvy a tmavý režim. Každý text v UI přes `L("…")` (anglický US text jako klíč), pak `make l10n` a přeložit české `TODO translate` v `Resources/cs.lproj/Localizable.strings` ve stejném commitu. Čeština musí být vždy kompletní (`make l10n-check` je součást `make test`). Postup a pravidla textů: `docs/preklady.md`.
- **Bezpečnost** (sekce Bezpečnost v `docs/PLAN.md`): hesla jen v Klíčence; nikdy v argumentech procesů, proměnných prostředí, logu ani souborech. Procesy spouštět s polem argumentů, nikdy přes shell se složeným řetězcem. Neznámý projekt = Omezený režim (nespouštět jeho nástroje ani příkazy z jeho nastavení). SSH jen se ověřeným klíčem serveru. Helpery jen přes stdin/stdout, nikdy síťový port.
- Když se rozhodnutí z plánu ukáže jako špatné, zastav a popiš varianty. Technologii neměň sám.
- Swift: taby, Swift 6 strict concurrency. Go: `gofmt`, jen stdlib + povolené závislosti, cgo jen pro SQLite.
