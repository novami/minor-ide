# Security Policy

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting
(Security tab › Report a vulnerability). Include the version, the steps to reproduce and the impact.
Reports are answered on a best-effort basis; this is a one-person project.

## Supported versions

There is no public release yet. Until one exists, only the `main` branch is supported.

## Security model

MinorIDE stores database credentials and runs project tools, which execute foreign code.

## Threats and protections

| Threat | Example | Protection |
|---|---|---|
| Stolen stored secrets | malware reads files in `~/Library` | secrets only in the Keychain (file-based login keychain, no iCloud), files hold only item IDs; item ACL bound to the app's signature |
| Secret visible to other processes | `ps`, environment dumps | secrets go to child processes only through stdin or askpass, never through arguments or environment variables |
| Secret in logs or clipboard | debug log, copied password | `os.Logger` with `privacy: .private`, connection parameters never logged; a copied secret is marked concealed and cleared after 60 s |
| Man in the middle | forged SSH host, fake TLS certificate | `known_hosts` with fingerprint confirmation, a changed key is rejected; TLS always verifies certificates |
| Malicious project | `phpstan.neon` bootstrap, Composer scripts, compose file mounting `~`, `.minoride/settings.json` commands | **Restricted Mode**: until the user trusts the project, no tool, script or command from the project runs; built-in parsers still work because they never execute code; trust is stored per path outside the project |
| Code in repository or toolchain configuration | `core.fsmonitor` in `.git/config`, `toolchain` line in `go.mod` | Restricted Mode runs no `git`, gopls, `go`, Composer, Docker, run configuration or debugger; outside Restricted Mode, `go` runs with the project's toolchain only after trust (`GOTOOLCHAIN=local` before) |
| Docker escape to the host | `privileged: true`, bind mount of `/` or `~` | warning before `up` when a compose file uses privileged mode, host networking or mounts outside the project; no Docker command in Restricted Mode |
| Destructive Docker or dependency action | `down -v`, `prune`, `composer update` | impact preview and confirmation; volumes never removed automatically; `composer install` never updates |
| Forged update | compromised GitHub account | MinorUpdater: HTTPS only, SHA-256 of the archive, same Developer ID Team ID, no downgrade |
| Compromised dependency | malicious new version | dependencies pinned (exact SwiftTerm version, PHP stubs tag), GitHub Actions pinned by SHA, updates reviewed by hand |
| Local network attack | another process connects to a helper | no listening ports except Delve on `127.0.0.1` during a debug session and the askpass Unix socket (`0700`, one-time token); SSH tunnels use `ssh -W` without a local port |
| Data loss | crash while saving, replace in files | atomic save preserving permissions, owner, extended attributes and symlink targets; Local History; crash backups; deleted files go to the Trash |
| Path traversal | `../` in names from archives, tools or servers | paths are normalized and must stay inside the target directory |

## Code rules

- No secret in the repository, logs, crash data, settings files or SQL history (passwords are removed from connection strings).
- Processes start through `Process` with an argument array, never through a shell with a composed string. The only shell use is reading the login environment, without user data.
- Child processes get a minimal, explicit environment.
- Hardened runtime without exceptions (`disable-library-validation`, `allow-jit` and similar are forbidden).
- Network access only for update checks (can be turned off) and connections the user creates.
- Parsers of untrusted input (PHP, Latte, NEON, JSON, tool output, database protocols) never trap and have size and time limits.

## Security tests

- A password never appears in the process table during a connection.
- A changed SSH host key is rejected.
- Restricted Mode runs neither PHPStan nor `git`: a repository with `core.fsmonitor` in `.git/config` executes nothing.
- A project with its own trust file or `.minoride/local.json` does not open as trusted.
- In Restricted Mode, `go` runs only with `GOTOOLCHAIN=local`.
