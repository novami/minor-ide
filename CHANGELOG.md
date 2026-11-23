# Changelog

All notable changes are listed here. The project has no tagged release yet.

## Unreleased

- Update checking: `UpdateKit` (feed, Ed25519 + SHA-256 verification, download), Settings › Updates
  with automatic check and automatic download (both on by default). "Install and Restart"
  swaps the bundle with rollback after checking bundle ID, version and code signature.
- `tools/release.sh`: local release build, zip and signed `appcast.json`.
- `tools/minorupdate.swift`: shared MinorUpdate signing key for several apps (key in the Keychain) and feed generation.
- SwiftLint findings fixed (force unwraps and casts replaced, small AppKit helpers).
- App target regrouped into `App`, `Features`, `Services` and `Diagnostics` folders.
- CI: actions pinned by commit SHA, cache keyed by Swift toolchain, advisory SwiftLint job.
