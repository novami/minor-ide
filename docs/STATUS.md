# Status

Working position. Updated after every finished block of work; a new session starts here. The detailed log until 2026-11-18 is in [archive/status-v1.md](archive/status-v1.md) (Czech).

**Last update:** 2026-11-23 (R2 done)

## Where we are

- Done: phases 0, 1a–1f (editor), 2b in code (manual check pending), 3 and R1 (gopls: completion, navigation, history, hover, signature help, diagnostics, quick fixes, rename, formatting, semantic tokens, restart after a crash), R2 (localization engine). Details in [ROADMAP.md](ROADMAP.md#done).
- Postponed: phase 2 (release and updater) until an Apple Developer account exists.
- The architecture was revised on 2026-11-22 after a new product specification. Decisions: [DECISIONS.md](DECISIONS.md). The old plan is archived.
- Editor performance (M2, `make bench`): typing p99 0.11 ms, newline 0.31 ms, scroll 0.20 ms, jump 0.43 ms, 1 M rope edits in 0.74 s.
- The app still uses the Go helper for Find in Files; it is ported in R3.

## Next step

1. Spikes S1 ([spike-php-swift.md](spike-php-swift.md)) and S2 ([spike-tls.md](spike-tls.md)) are done; ADR-4 and ADR-7 hold. S2 code: `Sources/TLSSpike` (framer that sends the TLS request, then `prependApplicationProtocol` with TLS). TLS 1.3 with a test CA against PostgreSQL 17 and MariaDB 11; system trust and servers without TLS are rejected.
2. Spike S3 measured (`make bench-startup`, results in [PERFORMANCE.md](PERFORMANCE.md#measurements)): warm start ~180 ms (budget 200 ms, at the limit), welcome window 75–93 ms, idle 33–37 MB. Waiting for the owner to confirm the 100 MB idle target; real cold start needs `sudo purge`.
3. **R1 done** (2026-11-23): 3.8 was never built, nothing to remove. "Done when" checked on `~/MinorDLNA` with `MINORIDE_LSP_CHECK=1 MINORIDE_OPEN=<file.go> --snapshot <png> <project>`: all of 3.4–3.7 pass, then gopls is killed (SIGKILL) and restarts (1/3) and serves the open file again. `GoplsTests` kills the real gopls too and checks that the unsaved text came back. The hover step of the check had failed since 6e (a redraw after semantic tokens looks up the word under the real mouse and cancels the simulated hover); it now waits for redraws to settle. Bench BUDGET OK (typing p99 0.24 ms, Go 0.42 ms).
4. **R2 done** (2026-11-23): `Sources/Localization` (JSON files, CLDR plural rules, named parameters with locale formats, fallback chain, `⟦key⟧` for a missing translation in debug), `minoride-l10n` in Swift (`make l10n` generates `Strings.swift`, `make l10n-check` validates and is part of `make test`, `bundle` copies the files into the app with one `.lproj` per language and `InfoPlist.strings` from `infoPlist.*`). All 601 `L`/`LP` calls converted to 459 keys (Czech 100 %); `.strings`, `.stringsdict`, `translations.md` and the Go tool removed. Settings › General › Language (stored as `language` in settings.json) with an offer to restart (windows are kept). Bench BUDGET OK.
5. **Next: R3** (project system and search in Swift, [ROADMAP.md](ROADMAP.md#r3-project-system-and-search-in-swift--3-weeks)).

## Open items

- **Semantic tokens**: no `workspace/semanticTokens/refresh` and no delta requests; files changed by an external tool refresh only after an edit or a save. Bench today runs about 2× slower than the numbers above even without changes (machine noise); it stays within budget.

- **Manual check debt** (postponed by the owner until phase 3 is done): phase 2b with the owner, launched from Finder. R2: change Settings › General › Language, confirm the restart, check that windows come back in the new language and that standard menu items (Services, Window) follow it.
- **Localization**: `findInFiles.replaceConfirmation` and `usages.title` still join two plural texts (“5 matches in 3 files”); fine in Czech and English, may need full sentences for other languages. The Help Book keeps its own `InfoPlist.strings` (book title), which belongs to the HTML help.
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
