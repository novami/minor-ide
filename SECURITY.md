# Security Policy

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting
(Security tab › Report a vulnerability). Include the version, the steps to reproduce and the impact.
Reports are answered on a best-effort basis; this is a one-person project.

## Supported versions

There is no public release yet. Until one exists, only the `main` branch is supported.

## Model

The threat model, secret handling, Restricted Mode for untrusted projects and the update
verification design are described in [docs/SECURITY.md](docs/SECURITY.md).
Updates are verified with an Ed25519 signature over the SHA-256 digest of the archive and are
fetched only over HTTPS. Update delivery is not enabled in any build yet (no signing key, no feed).
