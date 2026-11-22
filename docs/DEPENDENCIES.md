# Dependencies

Goal: as few third-party libraries as possible. macOS system frameworks (AppKit, SwiftUI, Core Text, CryptoKit, Security, Network, FSEvents, SQLite3, CommonCrypto) are not counted as dependencies. A new dependency needs the owner's approval.

## Current set

| Dependency | Kind | Why not own code | License |
|---|---|---|---|
| SwiftTerm (exact pinned version) | Swift package | a terminal emulator would take 5–8 weeks | MIT |
| Official PHP stubs (`*.stub.php` from php-src and PECL repositories, pinned tag) | data | thousands of function signatures; only the vendor's own data is acceptable | PHP License / per repository, checked before bundling |

## Own implementations (instead of a library)

| Area | Choice | Note |
|---|---|---|
| Editor | own rope and Core Text rendering | ADR-3 |
| Lexers and parsers (PHP, Latte, NEON, PHPDoc, JSON with duplicate detection) | own | ADR-4 |
| LSP and DAP types, JSON-RPC | own, only the used subset | |
| Updater | own (GitHub Releases, Ed25519 through CryptoKit, code signature) | |
| Find in Files, fuzzy matcher, Myers diff, `.gitignore` matcher | own | ADR-11 |
| MySQL and PostgreSQL protocols | own over Network.framework | ADR-7; TLS upgrade per spike S2 (passed) |
| SQLite | system library through the `SQLite3` module | |
| Localization engine and plural rules | own | ADR-9 |
| Markdown for release notes | `AttributedString(markdown:)` | system |

## External tools (used through their CLIs, never bundled)

gopls, go, dlv, staticcheck, golangci-lint, govulncheck, php, composer, phpstan, psalm, php-cs-fixer, phpcs, phpunit, Nette Tester, docker and docker compose, git, ssh.

## Removed with the Swift-only decision (ADR-1)

The Go module `server/` and the planned Go dependencies (`go-sql-driver/mysql`, `jackc/pgx/v5`, `golang.org/x/*`) are no longer planned. The previous version of this document is in git history.
