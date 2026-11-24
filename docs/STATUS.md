# Status

Working position. Updated after every finished block of work; a new session starts here. Older logs: [archive/status-v1.md](archive/status-v1.md) (until 2026-11-18, Czech), [archive/status-pre-migration.md](archive/status-pre-migration.md) (until 2026-11-23).

**Last update:** 2026-11-24 (PR 1 merged, starting PR 3)

## Where we are

- PR 1 (migration to the Minor common base) is merged into `main` (merge commit `d4a0df1`): Xcode project, MinorLog/MinorKeychain/MinorUpdater, SwiftTerm 1.18.0, XCTest, SwiftLint `--strict`. Decisions: ADR-15 in [DECISIONS.md](DECISIONS.md).
- The ruleset on `main` is not created yet (see Open items).
- Feature state is unchanged from before the migration (editor, gopls, project search, databases, remote, terminal). PHP highlighting is the line-based `Core/Highlight/Lexers/PHPLexer.swift`; PHP intelligence does not exist yet (the old `PHPKit` spike was removed, see git history, commit 914bb28).

## Next step

1. Create the ruleset on `main` (required checks `lint / swiftlint`, `test / xctest`, integration_id 15368, PR with 0 approvals, no deletion, `non_fast_forward`); `main` has none today.
2. PR 3 (branch `php-lexer`, code done, not pushed): full-text `PHPTokenizer` in `Core/PHP/` (flat tokens, never traps, mutation test) plus highlighter additions (`die`, `__halt_compiler`, magic constants). Still to do before PR 4: keyword table and PHPDoc/heredoc-interpolation tokens in the tokenizer if the parser needs them. Then (4) parser with error recovery, (5) index, Composer autoload and stubs, (6) completion/definition/hover, (7) types and PHPDoc, (8) usages, rename, diagnostics, (9) toolchains and process environment (may go earlier for stub generation), (10) LSP client cleanup for gopls (`actor`, own data model), (11) run, tests, Composer, (12) terminal polish, (13) Git.

## Open items

- **Not verified**: signed release, notarization, updater against a real release, manual UI check of the app launched from Finder (an app started from the assistant's shell gets no input).
- **Help book**: the `MinorIDE.help` search indexes (`hiutil`) are no longer generated; the pages open, Help search is empty until an index step exists.
- **Benchmarks**: `make bench`, startup and catalog benchmarks were removed with the Makefile; the editor budget in [PERFORMANCE.md](PERFORMANCE.md) needs an XCTest `measure` replacement.
- **Debt carried over**: `tools/` has `make-icon.swift`; `ANALYSIS.md` names other products and must be removed or rewritten; several docs are still in Czech; the AppIcon is `Resources/AppIcon.icns` (asset catalog icon is empty).
- **CI**: the lint job uses the rule set in `.swiftlint.yml` (former exemptions carried over: identifier names, lengths, nesting).
- **Secrets** are not set. Release needs `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` and `DEVELOPMENT_TEAM` in `Config/App.xcconfig`.
- **Decisions still open**: PHP binary source (static-php-cli builds or detection only), PHP formatting beyond indentation.

## Environment notes

- Xcode 26 with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) is required to build SwiftTerm.
- Go and Composer come from Homebrew; test PHP project: `composer create-project nette/web-project <dir> --no-interaction --no-scripts`.
- Push: `git -c credential.helper= -c credential.helper='!gh auth git-credential' push`.
- App debug flags: `--snapshot <png> [file]`, `--dump-menu`, `--l10n-sample` (with `-AppleLanguages "(cs)"`).
