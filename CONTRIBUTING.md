# Contributing

MinorIDE is a native macOS IDE for PHP and Go, written in Swift for Apple Silicon (macOS 26+).
Start with [docs/STATUS.md](docs/STATUS.md) (current position) and [docs/ROADMAP.md](docs/ROADMAP.md).

## Workflow

- `xcodebuild test -scheme MinorIDE -destination 'platform=macOS,arch=arm64'` runs the XCTest suite; `swiftlint lint --strict` must be clean.
- Changes to the editing path must stay within the budget in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).
- `tools/l10n.sh generate` regenerates `Strings.swift` after editing `Resources/Localization/en-US.json`;
  every UI text needs an English and a Czech entry in the same commit.

## Rules

- Swift only (no new Go code), tabs for indentation, Swift 6 strict concurrency.
- Modules below the UI must not import AppKit.
- No new dependency without discussion ([docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)).
- Code, comments and documentation in simple US English.
- Small commits, each with a test for the main path. SwiftLint runs in CI as advisory only.
