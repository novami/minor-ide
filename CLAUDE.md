# MinorIDE

Nativní IDE pro PHP a Go na macOS (Apple Silicon), celé ve Swiftu. Popis, architektura a rozhodnutí: `README.md`; pravidla pro přispěvatele: `CONTRIBUTING.md`; bezpečnostní model: `SECURITY.md`. Další dokumenty neexistují (historie je v gitu).

## Příkazy
- Test: `xcodebuild test -scheme MinorIDE -destination 'platform=macOS,arch=arm64'`; `swiftlint lint --strict` musí být čistý (CI vynucuje)
- Build: `xcodebuild -scheme MinorIDE -destination 'platform=macOS,arch=arm64' build`; Release s `CODE_SIGNING_ALLOWED=NO`
- `Tools/l10n.sh generate` po změně `Resources/Localization/en-US.json` (validaci hlídá `ToolingTests`)
- Push: `git -c credential.helper= -c credential.helper='!gh auth git-credential' push`

## Pravidla
- Pravidla kódu, závislostí, lokalizace, HIG a výkonu jsou v `CONTRIBUTING.md`, bezpečnost v `SECURITY.md`. Zde jen to, co z nich přímo nevyplývá:
- Žádná nová závislost bez souhlasu. Povolené: `minor-swift-core`, SwiftTerm (pinnutý přesně). Stuby PHP přes Reflection z vybraného PHP.
- Neznámý projekt = Omezený režim (žádné nástroje, Git, gopls, Composer, Docker, debugger z projektu); hesla jen v Klíčence, nikdy v argumentech, prostředí ani logu.
- Když se rozhodnutí z README („Design decisions“) ukáže jako špatné, zastav a popiš varianty; technologii neměň sám.
- Kód, komentáře a dokumentace anglicky; tento soubor a odpovědi česky. Žádná zmínka o konkurenčních IDE.
- Implementuj sám, bez delegace na Sonnet subagenta.
- GUI: aplikace spuštěná z mého shellu nedostává vstup; ruční test nech na uživateli (spuštění z Finderu). `--snapshot` nevidí chyby vrstev, ověřuj složené okno.
- Dokumentaci neprodukuj navíc: README/CONTRIBUTING/SECURITY/CHANGELOG, postup vydání jen v README.

## Workflow
Po dokončeném bloku aktualizuj „Pracovní pozici“ níže, commitni a řekni uživateli, že může vyčistit kontext. Na „pokračuj“ čti pozici a jeď podle „Next step“.

## Pracovní pozice (aktualizováno 2026-11-24)
- Hotovo: migrace na Minor základ (merged), PHP tokenizer (větev `php-lexer`, PR 3 otevřený).
- Next: ruleset na `main` (checks `lint / swiftlint`, `test / xctest`); pak PHP parser s obnovou po chybách, index + Composer autoload + stuby, completion/definition/hover, typy a PHPDoc, usages/rename/diagnostika, toolchainy, úklid LSP klienta, run/testy/Composer, terminál, Git.
- Otevřené: neověřen podepsaný release, notarizace, updater a ruční test z Finderu; Help book bez vyhledávacích indexů; chybí XCTest benchmark editoru; chybí secrets pro release; nerozhodnuto: zdroj PHP binárky, formátování PHP.
- Prostředí: Xcode 26 s Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
