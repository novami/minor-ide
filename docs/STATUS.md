# Status

Working position. Updated after every finished block of work; a new session starts here. The detailed log until 2026-11-18 is in [archive/status-v1.md](archive/status-v1.md) (Czech).

**Last update:** 2026-11-22 (architecture revision: Swift only, PHP intelligence in the app, new document set)

## Where we are

- Done: phases 0, 1a–1f (editor), 2b in code (manual check pending), 3 steps 1–6c (gopls: completion, navigation, history, hover, signature help, diagnostics, quick fixes, rename). Details in [ROADMAP.md](ROADMAP.md#done).
- Postponed: phase 2 (release and updater) until an Apple Developer account exists.
- The architecture was revised on 2026-11-22 after a new product specification. Decisions: [DECISIONS.md](DECISIONS.md). The old plan is archived.
- Editor performance (M2, `make bench`): typing p99 0.11 ms, newline 0.31 ms, scroll 0.20 ms, jump 0.43 ms, 1 M rope edits in 0.74 s.
- The app still uses the Go helper for Find in Files and the Go tool for localization. Both are ported in R2 and R3.

## Next step

1. **Owner reviews the new document set** (PRD, ARCHITECTURE, DECISIONS, SECURITY, PERFORMANCE, LOCALIZATION, ROADMAP).
2. **R0 spikes**: S1 (PHP parser in Swift), S2 (TLS upgrade through a Network.framework framer), S3 (startup and idle memory).
3. **R1**: phase 3 step 6d (formatting ⌥⌘L, selection, on save), then 6e (semantic tokens over the lexer).

## Open items

- **Manual check debt** (postponed by the owner until phase 3 is done): phase 2b with the owner, launched from Finder.
- **Unpushed local commits**: push only when the owner asks, then check the CI run.
- **CI**: the benchmark uses the `ci` profile (p99 only); confirm on the next run.
- **Documents still in Czech**: `ANALYSIS.md`, `editor-behaviors.md`, `format-settings.md`, `keymap.md`, `spike-*.md`, `sponsors.md`, `translations.md`. Translate them when they are next touched. `ANALYSIS.md` names other products and must be removed or rewritten (ADR-13, branding rule).
- **Xcode** must be installed for SwiftUI macros (ADR-2).
- **Apple Developer account** for phase 2.

## Environment notes

- Only Command Line Tools are installed until Xcode is installed. Always run tests through `make test`, because it works around a SwiftPM issue with Swift Testing. SwiftUI macros (`@State`, `@Entry`) are missing; `@Observable` works.
- Go 1.27.4 and Composer 2.11 are installed through Homebrew.
- Push: `git push`. If git has no credentials: `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`.
- Test PHP project: `composer create-project nette/web-project <dir> --no-interaction --no-scripts`.
- App debug flags: `--bench`, `--snapshot <png> [file]`, `--dump-menu`, `--l10n-sample` (with `-AppleLanguages "(cs)"`).
- An app launched from the assistant's shell renders but gets no user input. Manual tests must be started by the owner from Finder.
