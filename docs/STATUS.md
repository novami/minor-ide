# Status

Working position. Updated after every finished block of work; a new session starts here. The detailed log until 2026-11-18 is in [archive/status-v1.md](archive/status-v1.md) (Czech).

**Last update:** 2026-11-23 (audit: update checking, CI, repo files)

## Where we are

- Done: phases 0, 1a–1f (editor), 2b in code (manual check pending), 3 and R1 (gopls: completion, navigation, history, hover, signature help, diagnostics, quick fixes, rename, formatting, semantic tokens, restart after a crash), R2 (localization engine). Details in [ROADMAP.md](ROADMAP.md#done).
- Postponed: phase 2 (release and updater) until an Apple Developer account exists.
- The architecture was revised on 2026-11-22 after a new product specification. Decisions: [DECISIONS.md](DECISIONS.md). The old plan is archived.
- Editor performance (M2, `make bench`): typing p99 0.11 ms, newline 0.31 ms, scroll 0.20 ms, jump 0.43 ms, 1 M rope edits in 0.74 s.
- Find in Files runs in Swift (`Sources/ProjectKit`: `.gitignore` rules, file walker, parallel searcher). The Go helper remains only for the database and PHP scan spikes until they are ported.

## Next step

1. Spikes S1 ([spike-php-swift.md](spike-php-swift.md)) and S2 ([spike-tls.md](spike-tls.md)) are done; ADR-4 and ADR-7 hold. S2 code: `Sources/TLSSpike` (framer that sends the TLS request, then `prependApplicationProtocol` with TLS). TLS 1.3 with a test CA against PostgreSQL 17 and MariaDB 11; system trust and servers without TLS are rejected.
2. Spike S3 measured (`make bench-startup`, results in [PERFORMANCE.md](PERFORMANCE.md#measurements)): warm start ~180 ms (budget 200 ms, at the limit), welcome window 75–93 ms, idle 33–37 MB. Waiting for the owner to confirm the 100 MB idle target; real cold start needs `sudo purge`.
3. **R1 done** (2026-11-23): 3.8 was never built, nothing to remove. "Done when" checked on `~/MinorDLNA` with `MINORIDE_LSP_CHECK=1 MINORIDE_OPEN=<file.go> --snapshot <png> <project>`: all of 3.4–3.7 pass, then gopls is killed (SIGKILL) and restarts (1/3) and serves the open file again. `GoplsTests` kills the real gopls too and checks that the unsaved text came back. The hover step of the check had failed since 6e (a redraw after semantic tokens looks up the word under the real mouse and cancels the simulated hover); it now waits for redraws to settle. Bench BUDGET OK (typing p99 0.24 ms, Go 0.42 ms).
4. **R2 done** (2026-11-23): `Sources/Localization` (JSON files, CLDR plural rules, named parameters with locale formats, fallback chain, `⟦key⟧` for a missing translation in debug), `minoride-l10n` in Swift (`make l10n` generates `Strings.swift`, `make l10n-check` validates and is part of `make test`, `bundle` copies the files into the app with one `.lproj` per language and `InfoPlist.strings` from `infoPlist.*`). All 601 `L`/`LP` calls converted to 459 keys (Czech 100 %); `.strings`, `.stringsdict`, `translations.md` and the Go tool removed. Settings › General › Language (stored as `language` in settings.json) with an offer to restart (windows are kept). Bench BUDGET OK.
5. **R3 in progress** ([ROADMAP.md](ROADMAP.md#r3-project-system-and-search-in-swift--3-weeks)). Done: Find in Files ported (ICU regex instead of RE2, same results and limits; Go `search` removed). Shared exclusion policy done (`MinorCore/ExclusionPolicy`, one `.gitignore` engine `GitIgnoreSet` for the file catalog and Find in Files; the duplicate in ProjectKit removed). Measured on 19 197 files ([PERFORMANCE.md](PERFORMANCE.md#measurements)): full walk ~100 ms, open-by-name ~1 ms, first Find in Files result 2–3 ms, so both R3 targets are met and the on-disk catalog with FSEvents event IDs is **postponed** (build it only if a cold-cache or very large project measures badly). Find in Files scopes done (whole project, open files, folder via sidebar “Find in Folder…”, file mask `*.php, !tests/**` in `MinorCore/PathMask`; not yet checked by hand in the UI). Replace All shows a before/after preview of the listed lines in its confirmation sheet (first 300 lines; not yet checked by hand). Next: `LanguageKit`/`LanguageProvider`, breadcrumbs and selection expand. 

## Open items

- **Updates (partial phase 2)**: `UpdateKit` checks an HTTPS feed, downloads and verifies SHA-256 + Ed25519; Settings › Updates (auto check and auto download default on, stored as `auto_check_updates`, `auto_download_updates`). Shared signing key "MinorUpdate" for all Minor* apps (Ed25519; private key only in the login Keychain, service `MinorUpdate`; tool `tools/minorupdate.swift keygen|sign`; signed message binds app ID + version + SHA-256). `make bundle` defaults: feed `https://github.com/novami/minor-ide/releases/latest/download/appcast.json` (public repo, release asset), the public key (override with `MINORIDE_UPDATE_FEED_URL`, `MINORIDE_UPDATE_PUBLIC_KEY`). No release exists yet, so the feed returns 404 and a check reports a failure. Back up the private key. Install is done in the app itself (`UpdateInstaller`: unzip with ditto, bundle ID and version check, `codesign --verify`, swap with rollback, relaunch through `open`), not by the helper `minoride-updater` from ARCHITECTURE.md. `tools/release.sh X.Y.Z` builds, zips and signs locally (no CI release: the key stays on the Mac); upload with `gh release create`. Missing: Developer ID and notarization (a first download in a browser is blocked by Gatekeeper), a test against the real GitHub feed (verified locally: release.sh, real zip and appcast.json, signature check and swap of a 0.0.0 copy to 0.0.1), `docs/release-notes/`.
- **SwiftLint** is advisory in CI (now 0 findings; rules documented in `.swiftlint.yml`); not yet seen in a CI run, as is the new SHA-pinned workflow.

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
