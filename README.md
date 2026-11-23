# MinorIDE

A native IDE for PHP and Go on macOS, written in Swift. Status: in development, no public release yet.

## Features (current)

- Own editor (rope, Core Text rendering, folding, find and replace, local history)
- Go: gopls integration (completion, navigation, hover, diagnostics, rename, formatting)
- PHP, Latte and NEON highlighting; PHP intelligence is planned in-app (no LSP)
- Quick Open, Find in Files with scopes and replace preview, Git change gutter, terminal
- English and Czech UI
- Update checks with automatic download (on by default, can be turned off in Settings › Updates)

## Requirements

- Apple Silicon Mac, macOS 14 or newer. Intel is not supported.
- Swift 6 toolchain (Xcode or Command Line Tools) and Go (for the temporary helper in `server/`).

## Build and test

```bash
make test     # Go and Swift tests
make bench    # editor benchmark
make run      # build build/MinorIDE.app and start it
```

## Structure

- `Sources/` — SwiftPM modules (`TextEngine`, `Highlight`, `EditorKit`, `LSPKit`, `PHPKit`,
  `ProjectKit`, `DBKit`, `RemoteKit`, `SecretsKit`, `UpdateKit`, `Localization`, `MinorCore`) and the
  app target `MinorIDE` (`App`, `Features`, `Services`, `Diagnostics`). Modules below the UI do not
  import AppKit.
- `Tests/`, `Resources/`, `tools/`, `server/` (temporary Go helper), `docs/`.
- Documentation: [docs/](docs/) (PRD, architecture, decisions, roadmap, status).

## Dependencies

SwiftTerm (pinned exactly). Everything else uses Apple system frameworks.

## Updates and distribution

The app can check a signed feed over HTTPS, download an update and verify its SHA-256 digest and
Ed25519 signature. Delivery is **not active yet**: there is no Developer ID signing, notarization,
release feed or signing key, and installing a downloaded update is not implemented. The release
design is in [docs/DECISIONS.md](docs/DECISIONS.md).

## License

MIT, see [LICENSE](LICENSE). Security: see [SECURITY.md](SECURITY.md).
