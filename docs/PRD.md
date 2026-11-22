# MinorIDE: Product Requirements

Native macOS IDE for PHP and Go. Swift, Apple Silicon, macOS 14+.

Related documents: [ARCHITECTURE.md](ARCHITECTURE.md), [DECISIONS.md](DECISIONS.md), [SECURITY.md](SECURITY.md), [PERFORMANCE.md](PERFORMANCE.md), [LOCALIZATION.md](LOCALIZATION.md), [UI-GUIDELINES.md](UI-GUIDELINES.md), [ROADMAP.md](ROADMAP.md), [STATUS.md](STATUS.md).

## Vision

A fast, native, reliable IDE that covers the full daily PHP and Go workflow (editing, navigation, search, tests, quality tools, Docker, databases, Git) without switching between applications. It is not a general-purpose editor and not a plugin platform.

Principles: performance first, native macOS behavior (Apple HIG), minimal dependencies, security by design, accurate intelligence over broad shallow features, a modular architecture that can add Python and Rust later.

## Users

Professional PHP (including Nette) and Go developers on macOS who work with Composer, Go modules, Docker Compose and MySQL/PostgreSQL databases.

## Scope

Legend: **MVP** = first release, **Later** = after MVP, **Out** = not planned.

### Editor
| Feature | Scope |
|---|---|
| Custom editor: syntax highlighting, line numbers, folding, multiple cursors and selections, smart indentation, bracket matching and auto-closing, comment toggling, line duplicate and move, find and replace, undo and redo, large files, line wrapping, sticky scope headers, whitespace visualization, font and ligature settings, light and dark themes | MVP (mostly done) |
| Native window tabs, split editor, tab pinning, recent files, breadcrumbs | MVP |
| Selection expansion and shrinking (syntax-aware) | MVP |
| Custom key bindings | MVP |
| Minimap | Later, only if it meets the performance budget |
| User-defined themes | Later |

### Project system, indexing, search
| Feature | Scope |
|---|---|
| Project detection (composer.json, go.mod, go.work, Docker and framework files) | MVP |
| File catalog with FSEvents, persisted, incremental; configurable exclusions, optional `.gitignore` policy | MVP |
| Open file by name, Find in Files with regex, case, whole word, include and exclude patterns, scopes (project, folders, extensions, patterns, open files, selected files), replace in files, progressive results, cancellation, report of skipped files | MVP |
| Go to Symbol, Search Everywhere, file structure | MVP |

### PHP (intelligence built into the app, no language server)
| Feature | Scope |
|---|---|
| Parser for PHP 7.2 to current stable, error recovery, version-aware syntax checks | MVP |
| Index of project, `vendor/` and official PHP stubs; namespace and import resolution; PHPDoc including generics | MVP |
| Completion, type inference, Go to Definition and Declaration, Find Usages, Implementations, Overrides, class hierarchy, symbol search, hover, signature help | MVP |
| Rename, Optimize Imports, quick fixes, inspections that report only certain problems | MVP |
| Extract Method and Variable, Change Signature, Safe Delete | Later |
| Composer: detection, version, install (respects the lock), update with preview, validate, diagnose, audit, package and autoload inspection, dependency tree, platform requirements | MVP |
| PHPStan, Psalm, PHP-CS-Fixer, PHP_CodeSniffer through their CLIs; format on save and selection; project configuration always wins | MVP |
| Tests: PHPUnit and Nette Tester | MVP |
| Tracy: open links from the error page and `bdump()` in the editor, log viewer, exception and stack trace view | MVP |
| PHP runtimes: detect installed versions and extensions, global and per-project selection, configuration inspection | MVP |
| Interactive PHP debugger (Xdebug) | Later |

### Nette
| Feature | Scope |
|---|---|
| Latte and NEON parsers, Nette DI model, presenter and template navigation, completion in Latte, Latte inspections | MVP |

### Go (gopls through LSP)
| Feature | Scope |
|---|---|
| Completion, navigation, rename, code actions (including extract), diagnostics, hover, formatting (gofmt and goimports) | MVP (mostly done) |
| go.mod, go.sum, go.work; toolchain selection through the `toolchain` directive and `GOTOOLCHAIN` | MVP |
| go vet, staticcheck, golangci-lint, govulncheck through their CLIs | MVP |
| Test UI: discovery, run single test, package, suite; results, failures with links, output, history, coverage, benchmarks, race detector | MVP |
| Delve debugger through DAP | MVP |

### Docker
| Feature | Scope |
|---|---|
| Engine status, containers, images, Compose projects; start, stop, restart, logs, terminal in container, build, resource usage; impact preview for destructive actions | MVP |

### Databases
| Feature | Scope |
|---|---|
| MySQL and MariaDB, PostgreSQL, SQLite: connections (direct, SSH tunnel, TLS where supported), schema browser, data grid with editing and SQL preview, SQL console, export | MVP |
| Redis | Later |
| MongoDB | Out |

### Tools and environment
| Feature | Scope |
|---|---|
| Git: change gutter, status, diff, commit by file and by hunk, blame, branches, pull and push, stash, conflict resolution, log | MVP |
| Terminal (SwiftTerm) | MVP (done) |
| Dashboard: recent projects and files, project health, runtime, Docker and test status, quick actions | MVP |
| Node.js, npm, pnpm, Yarn: detection and `package.json` scripts | Later |
| Remote servers: SSH, SFTP, FTPS, rsync, deployment | Later |
| Python and Rust | Later (architecture ready) |
| Generic external language servers, web server management, environment-variable management, plugin marketplace | Out |

### Platform
| Feature | Scope |
|---|---|
| English (US) source language, Czech always complete, one JSON file per language | MVP |
| Updates: signed, verified, one click | MVP |
| Accessibility: VoiceOver, keyboard-only use, Increase Contrast, Reduce Motion | MVP |
| Telemetry | Out |

## Native vs. delegated

| Native (implemented in MinorIDE) | Delegated to external tools |
|---|---|
| Editor, highlighting, PHP, Latte and NEON intelligence, file catalog and search, localization, Composer lock and dependency tree parsing, test runner UI, DAP client, database protocols, Docker and Git UI, updater | gopls, go, Delve, staticcheck, golangci-lint, govulncheck, php, composer, PHPStan, Psalm, PHP-CS-Fixer, PHP_CodeSniffer, PHPUnit, Nette Tester, docker and docker compose, git, ssh |

A missing external tool never blocks the editor. It disables only the feature that needs it and explains how to install it.

## Definition of done

A feature is done only when it works in a real macOS environment, has tests for the main path and the most important edge case, handles errors, meets its performance budget, has been reviewed against [SECURITY.md](SECURITY.md), has complete English and Czech texts, has user documentation where needed, and protects existing user data. Prototypes are always labeled as prototypes.
