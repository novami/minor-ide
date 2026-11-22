# Roadmap

Work proceeds phase by phase. A task ends when its **Done when** holds, its main path is tested, and it is committed. Detailed task text from the first plan (still valid where not changed here): [archive/plan-v1.md](archive/plan-v1.md).

Estimates are rough (one developer with AI). Remaining phases R0–R14 sum to about 55–64 weeks. With a 30 % reserve, the MVP is **about 17–19 months from now**.

## Done

| Phase | Content |
|---|---|
| 0 | Build without third-party tools (SwiftPM, bundle script, Makefile), editor, PHP scanner and helper spikes |
| 1a–1f | Custom editor: rope, selections, anchors, undo, Core Text rendering, input methods, mouse, line commands, find and replace, folding, lexers (Go, PHP, Latte, NEON, SQL, JSON, JS/TS, CSS/SCSS and more), project window, split editor, settings, safe save, Local History, backups, session restore, status bar, line wrapping, sticky headers, accessibility, system text features |
| 2b | Daily use: open file by name, Find in Files (currently through the Go helper), Git change gutter, terminal (manual check pending) |
| 3 (steps 1–6c) | LSP client and gopls: completion, go to definition, navigation history, hover, signature help, diagnostics, quick fixes, rename |

Postponed: **phase 2, release and updater**. It waits for an Apple Developer account, starts with a self-signed certificate (see the archive), and can be pulled forward at any time.

## R0 Architecture and spikes (≈ 2 weeks)
- New document set: PRD, ARCHITECTURE, DECISIONS, SECURITY, PERFORMANCE, LOCALIZATION, ROADMAP, STATUS (done).
- **S1 PHP parser in Swift** (done 2026-11-22, [spike-php-swift.md](spike-php-swift.md)): lexer and declaration scanner on flat arrays in `PHPKit`; 30 000 files in 0.33 s (budget 10 s), Laravel with `vendor/` in 94 ms, no trap, 0.6–1.5 KB of results per file.
- **S2 TLS upgrade** (done 2026-11-22, [spike-tls.md](spike-tls.md)): a Network.framework framer below TLS performs the PostgreSQL `SSLRequest` and the MySQL SSL handshake start. Done when TLS 1.3 is established against PostgreSQL 16 and MariaDB 11 in Docker with certificate verification, or the failure is documented and ADR-7 falls back.
- **S3 Startup and memory**: `--bench-startup` (cold, warm, Dashboard) and an idle `phys_footprint` sample. Done when the numbers are in PERFORMANCE.md and the 100 MB idle target is confirmed or revised with the owner.

## R1 Finish Go LSP (≈ 1 week)
- 3.7 formatting (⌥⌘L, selection, format on save) and semantic tokens over the lexer.
- Remove 3.8 (generic external language servers, ADR-5).
- Done when a real Go project has all of 3.4–3.7, key latency is unchanged, and the app survives a gopls crash.

## R2 Localization engine and migration (≈ 2 weeks)
- Engine, plural evaluator, generator, validator, migration as in [LOCALIZATION.md](LOCALIZATION.md); language setting with restart; generated `InfoPlist.strings`.
- Done when `.strings` and the Go l10n tool are gone, `make test` runs the validator, and Czech is 100 %.

## R3 Project system and search in Swift (≈ 3 weeks)
- `LanguageKit` with `LanguageProvider`; gopls moves behind it.
- Persistent file catalog with FSEvents event IDs, exclusion policy shared by all consumers, `.gitignore` policy.
- Find in Files ported to Swift (prefilter, streaming, cancellation, skipped-file report, scopes, replace in files with preview). The Go search helper is removed.
- File structure and breadcrumbs, selection expand and shrink through providers.
- Done when the Go module `server/` is no longer needed by the app, and on a 20 000-file project open-by-name stays < 50 ms and Find in Files shows first results in < 100 ms.

## R4 Go tools and test UI (≈ 3 weeks)
- `ToolKit` registry; Go environment and toolchain view; go vet, staticcheck, golangci-lint, govulncheck as diagnostics.
- `TestKit`: discovery, gutter run icons, run test, file, package and all, results tree, failure links, output, history, coverage in the gutter, benchmarks, race detector.
- Done when a failing Go test is found, run from the gutter and its failure opens the right line, and coverage shows after a run.

## R5 PHP intelligence (≈ 14–18 weeks, `PHPKit`)
Marker tests from the first day (`Tests/PHPKitTests/Markers/`):
```php
$user = new User();
$user->/*|complete: getName, getEmail*/;
$x = $user->getName/*|def: User.php:12*/();
```
Every new capability starts with a marker test; every fixed parser bug gets a fixture.

- **5a Lexer and parser, PHP 7.2 to current** (5–7 weeks): one lexer for highlighting and parsing, error recovery, PHPDoc parser, version checks, corpus tests over php-src `Zend/tests` and `vendor/` of large projects, random mutation tests. A new PHP release is a yearly task (lexer, parser, stubs, fixtures).
- **5b Index** (2–3 weeks): Composer metadata, stubs by PHP version, name resolution, hierarchy, traits, disk cache, incremental updates, `documentSymbol`-style outline, Go to Symbol.
- **5c Inference and completion** (3–4 weeks): type system, generics, narrowing, magic through PHPDoc and `@mixin`, completion with auto-import and ranking, definition, declaration, type definition, implementations, overrides, hover, signature help.
- **5d Usages, rename, inspections** (2–3 weeks): references from the inverted index verified by inference, rename (including the file by PSR-4), inspections only when certain, quick fixes (import, remove unused `use`, implement interface methods, create member, add PHPDoc), Optimize Imports, class hierarchy.
- Done when markers cover each point and, in a real Nette project, completion and middle-click navigation work on chained calls, all within budget.

## R6 PHP workflow (≈ 5–6 weeks)
- PHP runtimes: detection, extensions, global and per-project selection, `php.ini` view, requirement checks against `composer.json`.
- Composer: native lock and tree parsing, commands (install, update with preview, validate, diagnose, audit, check-platform-reqs), package view.
- Quality: PHPStan and Psalm on save, PHP-CS-Fixer and PHP_CodeSniffer with format on save and selection, batch inspection of the project.
- Tests: PHPUnit and Nette Tester in `TestKit`, discovery from the PHP index.
- Tracy: `minoride://open?file=…&line=…` URL scheme, path mapping for Docker, log viewer with stack traces and exception view.
- Option to run PHP tools through `docker compose exec <service>` with path mapping.
- Done when, in a real project, PHPStan problems show inline, format on save uses the project's fixer config, a PHPUnit failure opens the right line, and a Tracy link opens the editor.

## R7 Symbol navigation (≈ 1–2 weeks)
- Search Everywhere (files, symbols from all providers, actions), call hierarchy (gopls), type hierarchy (PHP, gopls).
- Done when a symbol is found in a 20 000-file project in < 100 ms.

## R8 Docker (≈ 3–4 weeks)
- `DockerKit` as in ARCHITECTURE: status, containers, images, Compose projects, actions, logs, terminal, stats, build, impact previews, Restricted Mode rules.
- Done when a Compose project can be started, inspected, logged and stopped without a terminal, and the app behaves correctly with Docker not installed, stopped and running (tests for all three).

## R9 Dashboard (≈ 1 week)
- Welcome window becomes the Dashboard: recent projects and files, project health, tools and runtimes, Docker and test status, quick actions, relevant notifications.
- Done when it renders in < 300 ms and every status links to the place where it can be fixed.

## R10 Databases (≈ 5 weeks)
- `DBKit` protocols (MySQL and MariaDB, PostgreSQL, SQLite), SSH tunnel through `ssh -W`, TLS per ADR-7, connection sheet, Keychain, schema browser, data grid with editing and SQL preview, SQL console with completion, export, production flag and dangerous-statement confirmation.
- Done when MariaDB works directly and through SSH, data editing shows its SQL first, and a 30-second query can be cancelled.

## R11 Git (≈ 4 weeks)
- Changes panel, side-by-side diff, commit by file and hunk, amend, blame, branches, pull and push, stash, three-way conflict resolution, log, credentials through the system helper and askpass.
- Done when a merge with conflicts in two files can be resolved and committed without a terminal.

## R12 Debugger (≈ 3 weeks)
- Run configurations, DAP client, breakpoints through anchors (conditional too), stack, variables, watches, stepping, evaluate, hover values; Delve for programs and tests.
- Done when a breakpoint in a Go test stops, variables can be read and stepping works, and no port stays open after the session.

## R13 Nette, Latte, NEON (≈ 5–7 weeks)
- Latte parser, NEON parser, DI model (services, autowiring, `inject*`, `#[Inject]`), presenter ↔ template mapping (`app/UI/<Name>/` and `app/Presenters/` + `templates/`), template variable types, completion in Latte, navigation from `{include}`, `{layout}`, `{link}`, `n:href`, `{control}`, `link()`, `redirect()`, `$this['name']`, Latte inspections.
- Done when, in a real Nette 3.2 project, middle-click navigation works between presenter, template and component, and member completion works in Latte.

## R14 Release quality (≈ 3 weeks)
- Phase 2 if not done earlier (Developer ID, notarization, updater), performance pass against all budgets, security review against SECURITY.md, accessibility audit, user documentation in both languages, final translation check.
- Done when a signed, notarized build updates itself, and every budget has a recorded result.

## After the MVP
Remote servers (SSH, SFTP, FTPS, rsync, deployment), Redis, Node.js tooling, Xdebug through a DBGp-to-DAP adapter, Extract Method and Variable, Change Signature, Safe Delete for PHP, minimap, user themes, Python and Rust providers, inlay hints, SQL inside PHP strings.

## Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | Editor has hundreds of small behaviors | high | TextEngine without AppKit, property-based tests, behavior checklist, daily use |
| R2 | PHP parser correctness across 7.2 to current, yearly releases | high | corpus, mutation tests, golden tests, parser never traps |
| R3 | PHP intelligence is the largest part | high | sub-phases 5a–5d, each usable; PHPStan and Psalm cover deep analysis |
| R4 | Swift parser speed (ARC, `String`) | high | flat arrays over `[UInt8]`, spike S1 before R5 |
| R5 | In-process analysis can crash or bloat the app | high | no traps, time and memory limits, cache eviction, tests on large projects |
| R6 | False inspections when inference is unsure | high | unknown is `mixed`, inspections only when certain, real-project corpus must be clean |
| R7 | TLS upgrade not possible without a library | closed | spike S2 passed |
| R8 | Performance regressions | high | benchmarks in CI fail on budget breaches |
| R9 | Docker CLI output changes between versions | medium | tests against recorded output of several versions; tolerant decoding |
| R10 | Varied PHP installations on macOS | medium | detection from several sources, manual path override |
| R11 | gopls uses 1–2 GB on large monorepos | medium | `directoryFilters` from the exclusion policy, warning in the UI |
| R12 | Total scope | high | strict phase order, use the app daily, cut candidates: R13 inspections, R11 log and stash, R10 export |
| R13 | Secret leaks, malicious projects | high | SECURITY.md rules and tests, Restricted Mode |
| R14 | Updater breaks an installation | high | two signature checks, atomic swap with rollback, interrupted-download test |
