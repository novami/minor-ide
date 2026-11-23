# Changelog

All notable changes are listed here. The project has no tagged release yet.

## Unreleased

- Update checking: `UpdateKit` (feed, Ed25519 + SHA-256 verification, download), Settings › Updates
  with automatic check and automatic download (both on by default). Installing an update is not
  implemented, and update delivery stays off until a feed URL and signing key are configured.
- App target regrouped into `App`, `Features`, `Services` and `Diagnostics` folders.
- CI: actions pinned by commit SHA, cache keyed by Swift toolchain, advisory SwiftLint job.
