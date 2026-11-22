# Architecture Decision Records

Each record: context, decision, consequences. Status is "accepted" unless stated. Records from the first plan (D1–D25) that still apply are folded in; their original text is in [archive/plan-v1.md](archive/plan-v1.md).

## ADR-1 Swift is the only implementation language
- **Context**: the app is already about 95 % Swift; Go was planned for the PHP server, database drivers, search and remote transfers.
- **Decision**: all product code is Swift. The existing Go spikes and tools (`server/`) are ported and removed. Go may return only with a measured benefit and explicit approval.
- **Consequences**: one toolchain to build the app, shared code between highlighting and analysis, no cgo. Database protocols and TLS must be handled in Swift (ADR-7).

## ADR-2 AppKit for the workspace, SwiftUI for panels
- **Context**: the editor, window tabs, split views and large tables need precise control and speed.
- **Decision**: the project window, editor, outline and tables use AppKit. Settings, the Dashboard, forms and panel content use SwiftUI where it meets the budgets. Xcode is installed for development so SwiftUI macros are available.
- **Consequences**: two UI toolkits with a clear boundary: SwiftUI views are hosted inside AppKit containers.

## ADR-3 Custom editor over Core Text
- **Context**: NSTextView and TextKit 2 were considered. Multiple cursors, folding, large files, gutter features and strict latency are hard to get from them.
- **Decision**: own rope (`TextEngine`) and Core Text rendering (`EditorKit`), zero dependencies. Measured: key press p99 0.11 ms, scroll 0.20 ms, 1 M rope edits on 10 MB in 0.74 s ([spike-editor.md](spike-editor.md)).
- **Consequences**: system text features (input methods, dictation, VoiceOver, services, Look Up) must be implemented by hand; a checklist and tests cover them ([editor-behaviors.md](editor-behaviors.md)).

## ADR-4 PHP intelligence is built into the app, without LSP
- **Context**: the product's PHP and Nette features depend on deep, controllable analysis. A separate server process or a third-party language server was rejected by the owner.
- **Decision**: `PHPKit` implements parsing, indexing, inference and features in-process behind `LanguageProvider`. External PHP tools (PHPStan, Psalm, PHP-CS-Fixer, PHP_CodeSniffer, Composer, PHPUnit, Tester) are used only through their CLIs.
- **Consequences**: a parser crash or memory spike would affect the app, so the parser must never trap and analysis has time and memory limits. A single PHP lexer serves highlighting and parsing.

## ADR-5 Go through gopls, the only LSP use
- **Context**: Go type checking in Swift would take years and be worse than the official tool.
- **Decision**: gopls through `LSPKit`. Generic external language servers configured by the user (old D23) are dropped. Future Python and Rust use their official servers through the same client.
- **Consequences**: other languages (JS, CSS, HTML, YAML…) get highlighting and editor commands only.

## ADR-6 Language provider interface
- **Decision**: every language implements `LanguageProvider` with provider-neutral models in `LanguageKit` ([ARCHITECTURE.md](ARCHITECTURE.md#language-providers)). The UI talks only to the protocol.
- **Consequences**: LSP types are mapped to `LanguageKit` models at the edge; adding a language does not touch the UI.

## ADR-7 Own database protocols, TLS without a library
- **Context**: MySQL and PostgreSQL (before 17) start TLS inside an open connection; Network.framework has no direct API for that. The only full library option (SwiftNIO with BoringSSL) is very large.
- **Decision**: own MySQL and PostgreSQL clients over `NWConnection` or `ssh -W` pipes; SQLite through the system library. Spike S2 tests a Network.framework framer below TLS for the in-connection upgrade. If S2 fails, supported options are direct TLS (PostgreSQL 17+), SSH tunnel and unencrypted local connections (accepted by the owner).
- **Consequences**: about one extra week compared with existing drivers; protocol fuzz-style tests and integration tests against MariaDB 11 and PostgreSQL 17 in Docker.

## ADR-8 Docker through the CLI
- **Decision**: `docker` and `docker compose` with JSON output; live state through `docker events`. No Engine API client.
- **Consequences**: respects `docker context` and credentials automatically; output formats are tested against several Docker versions.

## ADR-9 Localization: one JSON file per language, custom engine
- **Decision**: `Resources/Localization/<locale>.json`, semantic keys, named parameters, CLDR plural rules defined in the file metadata, typed accessors generated from `en-US.json`, a validator that fails the build. Language changes apply after restart. Design: [LOCALIZATION.md](LOCALIZATION.md).
- **Consequences**: replaces `.strings`/`.stringsdict` and the `L("…")` calls; `InfoPlist.strings` files are generated from JSON at build time.

## ADR-10 Runtimes: detect and select, never install silently
- **Decision**: PHP versions and extensions are detected and selected globally or per project; installation is a visible Homebrew command run on request. Go toolchains follow `go.mod` and `GOTOOLCHAIN`. No own downloads of runtimes.
- **Consequences**: no download and signature infrastructure for runtimes; the updater is the only downloader.

## ADR-11 Find in Files without a full-text index
- **Decision**: parallel scanning with a literal prefilter in the MVP; a trigram index only if measurements require it.
- **Consequences**: no index storage cost; search time grows with repository size, which is measured on a reference monorepo.

## ADR-12 Scope changes
- Nette, Latte and NEON stay in the MVP.
- Remote servers (SSH, SFTP, FTPS, rsync, deployment) move after the MVP.
- Git basics stay in the MVP.
- Redis and Node.js move after the MVP.
- The PHP interactive debugger (Xdebug) stays after the MVP; PHP is debugged through Tracy in the MVP.

## ADR-13 Documentation and source language
- **Decision**: code, comments, identifiers and project documentation are in simple American English. Czech appears only in localization resources. Instructions for the assistant (`CLAUDE.md`) may stay in Czech.

## ADR-14 Carried decisions from the first plan
| Topic | Decision |
|---|---|
| Name and license | MinorIDE, bundle id `cz.novami.minoride`, MIT |
| Highlighting | own incremental lexers with line-start state |
| Debugger | own DAP client; Delve for Go; Tracy for PHP in the MVP |
| Updates | own updater over GitHub Releases, Ed25519 signature signed locally (key never on GitHub), code signature check; self-signed certificate until a Developer ID exists, then notarization |
| Terminal | SwiftTerm (the only Swift library) |
| Build | SwiftPM and an own bundle script |
| Project trust | Restricted Mode for unknown projects; trust is stored outside the project |
| Secrets | Keychain only, no Touch ID |
| Telemetry | none |
| Sandbox | no App Sandbox; hardened runtime without exceptions; distribution outside the App Store |
| PATH | read once from the interactive login shell with markers and a timeout, with fallback paths |
| PHP stubs | official `*.stub.php` from php-src and PECL repositories, pinned to a release tag; availability for 7.2–7.4 from an own table |
| Network ports | none, except Delve on `127.0.0.1` during a debug session and the askpass Unix socket (`0700`, one-time token) |
| SSH | system OpenSSH only, `known_hosts` verification, never `StrictHostKeyChecking=no` |
