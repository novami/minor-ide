# MinorIDE: Technical Architecture

Decisions behind this document: [DECISIONS.md](DECISIONS.md). Scope: [PRD.md](PRD.md).

## Process model

```
MinorIDE.app/Contents
├─ MacOS/MinorIDE               Swift: UI, editor, PHP/Latte/NEON intelligence, indexing, search,
│                               Docker, databases, Git, terminal, LSP client (gopls), DAP client
├─ Helpers/minoride-askpass     small Swift CLI: SSH_ASKPASS / GIT_ASKPASS, asks the app for the secret
├─ Helpers/minoride-updater     small Swift CLI: replaces the app after it quits
└─ Resources/
   ├─ Localization/             en-US.json, cs-CZ.json (one file per language)
   └─ php-stubs/                official PHP and PECL stubs (data)

External processes (found in PATH or the project, never bundled):
gopls, go, dlv, staticcheck, golangci-lint, govulncheck, php, composer, phpstan, psalm,
php-cs-fixer, phpcs, phpunit, tester, docker, git, ssh
```

Only Swift is an implementation language. The Go module `server/` is a set of spikes and tools that is ported to Swift and then removed (see [ROADMAP.md](ROADMAP.md)).

## Threading

- Main thread: UI only.
- Editor snapshots are immutable (copy-on-write rope), so background work (highlighting, PHP analysis, saving, search) needs no locks.
- Background work runs in Swift Concurrency tasks with priorities: open file > visible project > whole project. Every task can be cancelled; a newer edit cancels stale analysis.
- Every process or network operation has a timeout and a cancel action and never runs on the main thread.

## Modules (SwiftPM targets)

| Target | Responsibility | AppKit |
|---|---|---|
| `MinorCore` | settings, logging, file I/O (safe save, Local History, backups), process execution, JSON-RPC framing | no |
| `Localization` | JSON localization engine, plural rules, formatting | no |
| `TextEngine` | rope, change sets, selections, anchors, undo/redo, search in buffer, folding model | no |
| `Highlight` | incremental line-state lexers, themes, language commands | no |
| `LanguageKit` | `LanguageProvider` protocol and provider-neutral models (completion, location, diagnostic, workspace edit, symbol, hover) | no |
| `PHPKit` | PHP lexer, parser, AST, PHPDoc, index, types, inference, features; Latte and NEON parsers; Nette model | no |
| `LSPKit` | LSP client and gopls provider; maps LSP types to `LanguageKit` models | no |
| `ProjectKit` | project detection, file catalog, FSEvents, exclusion policy, fuzzy matcher, Find in Files, navigation history | no |
| `ToolKit` | tool detection and versions, runtimes (PHP, Go), Composer, quality tools (PHPStan, Psalm, fixers, linters) with output parsers | no |
| `TestKit` | test discovery, runners (`go test -json`, PHPUnit and Tester JUnit XML), results, history, coverage | no |
| `DebugKit` | DAP client, Delve session | no |
| `DockerKit` | Docker CLI integration | no |
| `DBKit` | MySQL and PostgreSQL wire protocols, SQLite (system library), schema, query streaming | no |
| `GitKit` | `git` CLI integration, Myers diff | no |
| `SecretsKit` | Keychain, project trust, login-shell environment, askpass socket | no |
| `UpdateKit` | update check, download, verification | no |
| `EditorKit` | editor view (Core Text), input, carets, gutter, popups | yes |
| `TerminalKit` | terminal panel over SwiftTerm | yes |
| `MinorIDE` | windows, menus, panels, dashboard, settings, composition of modules | yes |

Rules: lower targets never import AppKit; UI for a module lives in `MinorIDE` (or `EditorKit`). New targets only when a boundary is real, not per feature.

## Language providers

```swift
protocol LanguageProvider: Sendable {
	var id: LanguageID { get }                      // php, go, latte, neon, later python, rust
	func detect(project: ProjectInfo) -> Bool
	func open(_ doc: DocumentSnapshot) async
	func change(_ doc: DocumentSnapshot, _ changes: ChangeSet) async
	func completion(at: Position, in: DocumentID) async throws -> CompletionList
	func definition(at: Position, in: DocumentID) async throws -> [Location]
	func references(at: Position, in: DocumentID) -> AsyncThrowingStream<Location, Error>
	func rename(at: Position, to: String, in: DocumentID) async throws -> WorkspaceEdit
	func diagnostics(for: DocumentID) -> AsyncStream<[Diagnostic]>
	// plus hover, signatureHelp, implementations, symbols, codeActions, formatting,
	// selectionRanges, foldingRanges, typeHierarchy, callHierarchy (each optional)
}
```

- **PHP, Latte, NEON**: `PHPKit` implements the protocol in-process.
- **Go**: `LSPKit` implements it by talking to gopls.
- **Python, Rust (later)**: an LSP provider for the official language server, plus a lexer and test adapter.

Capabilities a provider does not support are hidden in the UI, never shown as broken.

Each language also registers: a lexer (`Highlight`), format settings, a test adapter (`TestKit`), tools (`ToolKit`), and project detection rules.

## PHP intelligence (`PHPKit`)

- **One PHP lexer.** The parser lexer and the highlighting lexer share one state machine; `Highlight` uses it line by line with saved state, the parser uses it on whole files. A shared golden token corpus guards both uses.
- **Parser**: recursive descent for statements, Pratt parsing for expressions, error recovery (`Missing` nodes, synchronization on `;`, `}` and statement keywords). It accepts a superset of syntax; version checks are a separate pass driven by the project PHP version.
- **Memory layout**: the AST is stored in flat arrays (node kind, byte range, child indices as `Int32`) per file, not as class instances. This avoids ARC overhead and keeps parsing of 30 000 files within budget.
- **Index**: declarations with FQN, location, signature and PHPDoc; hierarchy and subtypes; inverted name index for references. Sources: project files, `vendor/` from Composer metadata, PHP stubs filtered by the project PHP version.
- **Persistence**: binary cache per file keyed by content hash in `~/Library/Caches/MinorIDE/php/<project-hash>/`; only changed files are reparsed; a `composer.lock` change reindexes `vendor/`.
- **Inference**: lazy and memoized per file version; native types, PHPDoc (including `@phpstan-` and `@psalm-` variants), generics, narrowing, closures. Unknown means `mixed`, and inspections stay silent on `mixed`.
- **Safety**: analysis runs inside the app process, so the parser must never trap. No force unwraps, bounds-checked access, a time limit per request, random mutation tests over the corpus, and a memory budget (see [PERFORMANCE.md](PERFORMANCE.md)).
- **Nette**: Latte and NEON parsers, DI model (services, autowiring), presenter and template mapping. PHP expressions in Latte reuse the PHP parser.
- **External analysis**: PHPStan and Psalm run through their CLIs (`--error-format=json`, `--output-format=json`) on save. Their diagnostics merge with built-in ones without duplicates.

## Go

- gopls through `LSPKit` provides completion, navigation, rename, code actions (including extract), diagnostics and formatting (gofmt and goimports through gopls).
- `ToolKit` runs `go vet`, `staticcheck`, `golangci-lint run` (JSON output; flags differ between v1 and v2) and `govulncheck -json`, and parses their output into diagnostics.
- Toolchains: show the `go` and `toolchain` lines from `go.mod` and the version `go env GOVERSION` resolves to. Go downloads toolchains itself through `GOTOOLCHAIN`; MinorIDE does not install toolchains. In Restricted Mode, `go` runs with `GOTOOLCHAIN=local` so that an untrusted `go.mod` cannot make Go download and run a toolchain.
- Tests: discovery from the Go lexer (`TestXxx`, `BenchmarkXxx`, `FuzzXxx`, `ExampleXxx` in `_test.go`), runs through `go test -json` with `-run`, `-bench`, `-race` and `-coverprofile`, and coverage shown in the gutter.
- Debugging: Delve through DAP (`dlv dap` on `127.0.0.1` with a random port, only during a session).

## Project system, indexing and search (`ProjectKit`)

- **File catalog**: path, size, mtime, kind (text, binary, generated, symlink) in a compact in-memory structure. It is persisted as a snapshot with the last FSEvents event ID in `~/Library/Caches/MinorIDE/projects/<hash>/`. On reopen, the catalog applies events since that ID instead of rescanning.
- **Exclusion policy**: one object used by the catalog, search, file watchers, PHP indexing and gopls `directoryFilters`.
  - Defaults: hidden directories (`.*`, except an allowlist such as `.github`), `vendor/` (indexed for symbols, excluded from text search by default), `node_modules/`, `cache/`, `tmp/`, `temp/`, `build/`, `dist/`, `coverage/`, `DerivedData/`.
  - Configurable per user and per project: included and excluded directories and extensions, maximum file size, hidden files, binary files, symlinks, generated files, and the optional `.gitignore` policy.
- **Symbol index**: owned by language providers (PHP index, gopls). Go to Symbol fans out to all providers and merges results.
- **Find in Files**:
  - No full-text index in the MVP. Parallel traversal with `getattrlistbulk`, chunked reads, a literal prefilter (`memmem`) extracted from the query, and the regular expression only on candidate lines.
  - Results stream to the UI in batches; a search can be cancelled.
  - Skipped files (binary, too large, not UTF-8, excluded) are counted and listed.
  - A full-text index is added only if measurements on the reference monorepo miss the budget.

## Tools and runtimes (`ToolKit`)

- **Tool registry**: name, resolved path (project `vendor/bin`, then user override, then PATH from the login shell), version, minimum version, install hint. Shown in Settings › Tools and on the Dashboard.
- **PHP runtimes**:
  - Detect binaries from Homebrew prefixes, PATH entries and version-manager directories.
  - For each binary, read `php -v`, `php -m` and `php --ini` (run from a temporary directory).
  - The project requirement comes from `require.php` and `config.platform.php` in `composer.json`. The selection is global (settings) and per project (`.minoride/local.json`, machine-specific).
  - Extensions are checked against `ext-*` requirements.
  - Installation: MinorIDE shows the Homebrew command and runs it in the terminal on request. It never overwrites an installation.
- **Composer**:
  - `composer.json` and `composer.lock` are parsed natively, including the dependency tree, autoload mapping and package information.
  - Commands run through the CLI with `--format=json` where available. `install` never updates; `update` first shows a dry-run diff of package changes.
  - Composer scripts run only in trusted projects.
- **Quality tools**: each tool has a runner (arguments array, project config discovery, JSON or checkstyle output parser). The project configuration always wins over global defaults.

## Docker (`DockerKit`)

- CLI only, with `--format json` output, so the active `docker context` (any local or remote engine) is respected without socket discovery.
- Status: `docker version`. States: not installed, not running, running. Each state has a clear explanation in the UI.
- Live updates through `docker events --format json` (no polling). Logs through `docker logs -f`. Terminal through `docker exec -it` in SwiftTerm. Resources through `docker stats --no-stream --format json`.
- Compose: discovery of `compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`. Project state through `docker compose ps --format json`; actions up, down (never `-v` by default), restart, build, logs.
- Safety: destructive actions show their impact first; volumes are never deleted automatically. Restricted Mode runs no Docker command against the project.
- Docker is optional at runtime. Without it, the Docker panel explains how to install or start it and nothing else changes.

## Databases (`DBKit`)

- Own wire protocol clients: MySQL and MariaDB (`mysql_native_password`, `caching_sha2_password` with RSA through the Security framework) and PostgreSQL v3 (SCRAM-SHA-256 through CryptoKit and CommonCrypto PBKDF2). SQLite through the system `SQLite3` module.
- Transport is a `ByteStream` protocol with two implementations: `NWConnection` (TCP, optional TLS) and the pipes of an `ssh -W host:port` process (SSH tunnel without a local port).
- TLS: TLS that starts after the protocol's own opening exchange uses a Network.framework framer that sends the TLS request and then prepends TLS above itself (`prependApplicationProtocol`, spike S2, [spike-tls.md](spike-tls.md)). No plaintext fallback. Also supported: direct TLS (PostgreSQL 17+), SSH tunnel, and unencrypted local connections as an explicit setting.
- Queries stream in pages; cancellation uses the protocol's cancel mechanism; values are lossless (NULL, binary, big numbers, ISO 8601 dates).

## Git (`GitKit`)

`git` CLI with porcelain v2 and `-z` output, own Myers diff for the gutter, credentials through the system credential helper, ssh-agent and `minoride-askpass`.

## Localization

Custom engine over one JSON file per language. Design: [LOCALIZATION.md](LOCALIZATION.md).

## Persistence

| Data | Location | Format |
|---|---|---|
| User settings | `~/Library/Application Support/MinorIDE/settings.json` | JSON |
| Project settings (shared) | `.minoride/settings.json` | JSON |
| Project local settings (machine-specific, not read in Restricted Mode) | `.minoride/local.json` | JSON |
| Trust, recent projects, session, test history | `~/Library/Application Support/MinorIDE/` | JSON |
| Caches (catalog, PHP index) | `~/Library/Caches/MinorIDE/` | binary, versioned, safe to delete |
| Secrets | Keychain | — |

SQLite is not used for app state. It is added only if a feature needs indexed queries over large data.

## UI structure

- **Welcome window = Dashboard**: recent projects and files, tool and runtime health, Docker status, last test results, quick actions (open, clone, new connection).
- **Project window** (native window tabs):
  - left navigator with modes: files, search, structure, tests, Docker, databases, Git;
  - editor in the center (split into two);
  - bottom panel: terminal, problems, test results, logs, run output;
  - status bar.
  - Panels are resizable, hideable and persistent.
- AppKit for the project window and the editor; SwiftUI for Settings, Dashboard, forms and panel content where performance allows.
