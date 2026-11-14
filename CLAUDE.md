# MinorIDE

Nativní IDE pro Go a PHP na macOS (Apple Silicon). Plán: `docs/PLAN.md`, závislosti: `docs/ZAVISLOSTI.md`.

## Příkazy
- `make test` – Go vet + testy, Swift testy (vždy přes make: SwiftPM s Command Line Tools potřebuje native build system a cesty k Swift Testing)
- `make bench` – výkonový benchmark editoru (release)
- `make bundle` / `make run` – sestaví a spustí `build/MinorIDE.app`
- `make server` – Go helper `server/bin/minoride-server`

## Pravidla
- Pracuj po úkolech v pořadí fází z `docs/PLAN.md`. Úkol končí splněním „Hotovo když“, testem hlavní cesty a commitem.
- Commity malé, jen vlastní soubory (`git commit -- <soubory>`), bez AI podpisů. Nikdy `git push` bez vyžádání.
- **Žádná nová závislost bez souhlasu uživatele.** Povolené: SwiftTerm, `go-sql-driver/mysql`, `jackc/pgx/v5` (+ jejich závislosti), `golang.org/x/*`, phpstorm-stubs (data). Systémové frameworky macOS a stdlib Go jsou volné.
- Na hlavním vlákně jen UI. Změna v editační cestě musí projít `make bench` v rozpočtu z plánu.
- `TextEngine`, `Highlight`, `LSPKit`, `MinorCore` nesmí importovat AppKit.
- phpls: každá nová schopnost začíná markerovým testem; každá opravená chyba parseru dostane fixture.
- Hesla a tajemství jen v Keychainu, nikdy do logů.
- Když se rozhodnutí z plánu ukáže jako špatné, zastav a popiš varianty. Technologii neměň sám.
- Swift: taby, Swift 6 strict concurrency. Go: `gofmt`, jen stdlib + povolené závislosti, cgo jen pro SQLite.
