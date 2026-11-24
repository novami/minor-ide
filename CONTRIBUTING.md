# Contributing

MinorIDE is a native macOS IDE for PHP and Go, written in Swift for Apple Silicon (macOS 26+). Build and layout: [README.md](README.md).

## Workflow

- `xcodebuild test -scheme MinorIDE -destination 'platform=macOS,arch=arm64'` runs the XCTest suite; `swiftlint lint --strict` must be clean (CI enforces both).
- Small commits, each with a test for the main path. Every PHP capability starts with a marker test; every fixed parser bug gets a fixture.
- Releases: a tag `X.Y.Z` runs `release.yml` (see [README.md](README.md#releases)).

## Rules

- Swift only, tabs, Swift 6 strict concurrency. Default isolation is MainActor, so new files in `Core/` (except `Editor`) declare `nonisolated`.
- Modules below the UI (everything in `Core/` except `Editor`) must not import AppKit. The main thread is for UI only.
- No new dependency without discussion. No reference to competing IDEs in UI, code or docs.
- PHP intelligence is built into the app (no LSP); LSP is only for gopls. The PHP parser must never trap (no `!`, checked indexes, time limit).
- Processes start with an argument array, never through a shell with a composed string. See [SECURITY.md](SECURITY.md).
- Code, comments and documentation in simple US English; Czech only in translations.

## Localization

Every UI text is `Strings.<key>`. Add the English text to `Resources/Localization/en-US.json` and the Czech to `cs-CZ.json`, run `Tools/l10n.sh generate`, and commit the JSON files with `Strings.swift` in one commit. Czech must stay complete and unused keys fail the check (`ToolingTests`). Adding a language means adding one file.

## UI

Follow the [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/): the standard menu bar and shortcuts (never override system ones), sheets instead of modal dialogs, a Settings window (⌘,) that applies changes immediately, system colors and dark mode, VoiceOver and full keyboard control. Background work never blocks the UI. Errors say what happened and what to do. Destructive actions have a preview and confirmation.

## Performance

Changes to the editing path must stay within budget (M2 reference hardware): key press to commit p99 < 8 ms, relex of a line < 1 ms, open a 10 MB file < 300 ms, PHP parse of a common file < 2 ms, open by name < 50 ms, idle memory < 100 MB. Language intelligence, databases and Docker start lazily; lists are virtualized; UI updates from background work are coalesced.
