# Status

Working position. Updated after every finished block of work; a new session starts here. The detailed log until 2026-11-18 is in [archive/status-v1.md](archive/status-v1.md) (Czech).

**Last update:** 2026-11-23 (spike S3 measured: startup and idle memory)

## Where we are

- Done: phases 0, 1a–1f (editor), 2b in code (manual check pending), 3 steps 1–6c (gopls: completion, navigation, history, hover, signature help, diagnostics, quick fixes, rename). Details in [ROADMAP.md](ROADMAP.md#done).
- Postponed: phase 2 (release and updater) until an Apple Developer account exists.
- The architecture was revised on 2026-11-22 after a new product specification. Decisions: [DECISIONS.md](DECISIONS.md). The old plan is archived.
- Editor performance (M2, `make bench`): typing p99 0.11 ms, newline 0.31 ms, scroll 0.20 ms, jump 0.43 ms, 1 M rope edits in 0.74 s.
- The app still uses the Go helper for Find in Files and the Go tool for localization. Both are ported in R2 and R3.

## Next step

1. Spikes S1 ([spike-php-swift.md](spike-php-swift.md)) and S2 ([spike-tls.md](spike-tls.md)) are done; ADR-4 and ADR-7 hold. S2 code: `Sources/TLSSpike` (framer that sends the TLS request, then `prependApplicationProtocol` with TLS). TLS 1.3 with a test CA against PostgreSQL 17 and MariaDB 11; system trust and servers without TLS are rejected.
2. Spike S3 measured (`make bench-startup`, results in [PERFORMANCE.md](PERFORMANCE.md#measurements)): warm start ~180 ms (budget 200 ms, at the limit), welcome window 75–93 ms, idle 33–37 MB. Waiting for the owner to confirm the 100 MB idle target; real cold start needs `sudo purge`.
3. **Next: R1**: phase 3 step 6d (formatting ⌥⌘L, selection, on save), then 6e (semantic tokens over the lexer).

## Open items

- **Manual check debt** (postponed by the owner until phase 3 is done): phase 2b with the owner, launched from Finder.
- **Unpushed local commits**: push only when the owner asks, then check the CI run.
- **CI**: the benchmark uses the `ci` profile (p99 only); confirm on the next run.
- **Documents still in Czech**: `ANALYSIS.md`, `editor-behaviors.md`, `format-settings.md`, `keymap.md`, `spike-*.md`, `sponsors.md`, `translations.md`. Translate them when they are next touched. `ANALYSIS.md` names other products and must be removed or rewritten (ADR-13, branding rule).
- **Xcode**: `xcode-select -p` now points to Xcode.app; check whether SwiftUI macros build and update the environment notes (ADR-2).
- **Apple Developer account** for phase 2.

## Environment notes

- Only Command Line Tools are installed until Xcode is installed. Always run tests through `make test`, because it works around a SwiftPM issue with Swift Testing. SwiftUI macros (`@State`, `@Entry`) are missing; `@Observable` works.
- Go 1.27.4 and Composer 2.11 are installed through Homebrew.
- Push: `git push`. If git has no credentials: `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`.
- Test PHP project: `composer create-project nette/web-project <dir> --no-interaction --no-scripts`.
- App debug flags: `--bench`, `--snapshot <png> [file]`, `--dump-menu`, `--l10n-sample` (with `-AppleLanguages "(cs)"`).
- An app launched from the assistant's shell renders but gets no user input. Manual tests must be started by the owner from Finder.
