# Status

Working position. Updated after every finished block of work; a new session starts here. Older logs: [archive/status-v1.md](archive/status-v1.md) (until 2026-11-18, Czech), [archive/status-pre-migration.md](archive/status-pre-migration.md) (until 2026-11-23).

**Last update:** 2026-11-24 (migration to the Minor common base, PR 1)

## Where we are

- Branch `migrate-to-minor-swift-core`: the app is now an Xcode project (starter layout, MinorLog/MinorKeychain/MinorUpdater, SwiftTerm 1.18.0), XCTest, SwiftLint `--strict` clean. Decisions: ADR-15 in [DECISIONS.md](DECISIONS.md), summary in the README.
- Local checks passed: `xcodebuild test`, `swiftlint lint --strict`, Release build with `CODE_SIGNING_ALLOWED=NO` (Info.plist: `MinorUpdateRepository = novami/minor-ide`, version 0.1.0, arm64), the app starts (`--dump-menu`).
- Feature state is unchanged from before the migration (editor, gopls, project search, databases, remote, terminal). PHP intelligence does not exist yet; the old spike (`PHPKit`) was removed, see git history.

## Next step

1. Push the branch (only when the owner asks), open the PR, wait for green CI, then create the ruleset on `main` (required checks `lint / swiftlint`, `test / xctest`, integration_id 15368, PR with 0 approvals, no deletion, `non_fast_forward`). `main` has no ruleset or branch protection today.
2. Then PRs in the order of the migration brief: (3) PHP lexer and highlighting, (4) parser with error recovery, (5) index, Composer autoload and stubs, (6) completion/definition/hover, (7) types and PHPDoc, (8) usages, rename, diagnostics, (9) toolchains and process environment (may go earlier for stub generation), (10) LSP client cleanup for gopls (`actor`, own data model), (11) run, tests, Composer, (12) terminal polish, (13) Git.

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
