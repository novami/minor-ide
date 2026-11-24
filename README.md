# MinorIDE

A native IDE for PHP and Go on macOS, written in Swift. Status: in development, no public release yet.

## Features (current)

- Own editor (rope, Core Text rendering, folding, find and replace, local history)
- Go: gopls integration (completion, navigation, hover, diagnostics, rename, formatting)
- PHP, Latte and NEON highlighting; PHP intelligence is planned in-app (no LSP)
- Quick Open, Find in Files with scopes and replace preview, Git change gutter, terminal
- Databases and remote servers (own protocols), English and Czech UI
- Update checks from GitHub Releases (Settings › Updates)

## Requirements

macOS 26 or newer on Apple Silicon (arm64 only), Xcode 26 with the Metal Toolchain component
(`xcodebuild -downloadComponent MetalToolchain`, needed by SwiftTerm).

## Build and test

```bash
xcodebuild test -scheme MinorIDE -destination 'platform=macOS,arch=arm64'
swiftlint lint --strict
tools/l10n.sh generate    # after editing Resources/Localization/en-US.json
```

## Architecture

The project is an Xcode project with synchronized folders; all build settings are in `Config/*.xcconfig`
(identity in `App.xcconfig`, version in `Version.xcconfig`). It is built on
[minor-swift-core](https://github.com/novami/minor-swift-core) (MinorLog, MinorKeychain, MinorUpdater)
and the [minor-swift-starter](https://github.com/novami/minor-swift-starter) template.

- `App/` — entry point, menus, windows. The workspace window is AppKit, settings and panels are SwiftUI (ADR-2).
- `Core/` — engine code below the UI: `Text` (rope), `Highlight`, `Editor`, `LSP` (gopls client),
  `Project`, `Database`, `Remote`, `Security`, `Localization`, `Support`. Everything except `Editor`
  must not import AppKit. Default actor isolation is MainActor, so these folders are marked `nonisolated`.
- `Features/` — UI features (editor, project, settings, database).
- `Tests/` — XCTest. `Resources/` — language files, help book, licenses. `docs/` — design documents.

Decisions taken at the migration (details in [docs/DECISIONS.md](docs/DECISIONS.md), ADR-15):

- Own editor and rendering are kept (ADR-3), no `NSTextView`.
- PHP: own lexer, parser, index and type inference in `Core/PHP` (no LSP, ADR-4). Built-in functions and
  classes (stubs) are generated through Reflection by the selected PHP and cached per version.
  Formatting: own indentation only, `php-cs-fixer` optional as an external tool.
- Go: own LSP client and `gopls` (ADR-5).
- PHP and Go toolchains: existing installations are detected (Homebrew, `/usr/local`, asdf, mise); the PHP
  download source is still open. Project settings live in `.minoride/` inside the project, trust decisions outside it.
- Project search stays the Swift implementation without an index (ADR-11).
- Distribution: Developer ID, notarization and MinorUpdater only. No sandbox, hardened runtime.

## Dependencies

- minor-swift-core (`upToNextMinorVersion` from 0.1.1), MIT.
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.18.0 (pinned exactly), MIT. The licence text is in
  `Resources/Licenses/SwiftTerm.txt` and in the About window.

Everything else uses Apple system frameworks.

## Releases

A tag `X.Y.Z` runs `release.yml`: lint, tests, build, Developer ID signing, notarization and a GitHub Release with
`MinorIDE-X.Y.Z.zip`. **A release fails until these repository secrets exist:** `DEVELOPER_ID_P12`,
`DEVELOPER_ID_P12_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`. Set `DEVELOPMENT_TEAM` in
`Config/App.xcconfig` first.

## License

MIT, see [LICENSE](LICENSE). Security: see [SECURITY.md](SECURITY.md).
