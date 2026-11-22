# Spike S2: TLS upgrade inside a database connection

**Result: passed (2026-11-22).** Network.framework can upgrade an open TCP connection to TLS without a library, so ADR-7 holds without the fallback.

## Approach

`Sources/TLSSpike` (executable, not part of the app). The connection stack is TCP plus one custom `NWProtocolFramer`; TLS is **not** in the initial stack.

1. The framer's `start` returns `.willMarkReady`, so the app sees no data until the upgrade is done.
2. PostgreSQL: the framer writes `SSLRequest` (length 8, code 80877103) and reads one byte. MySQL/MariaDB: the framer reads the server greeting (v10), checks that the server offers `CLIENT_SSL`, and writes the SSLRequest packet (sequence 1). The greeting is handed to the client through a context object stored in the framer options.
3. The framer calls `prependApplicationProtocol(options: tlsOptions)`, then `passThroughOutput()`, `passThroughInput()` and `markReady()`. TLS runs above the framer on the same TCP connection; the framer passes bytes through.
4. Certificate check: `sec_protocol_options_set_verify_block` with `SecTrustSetAnchorCertificates` + `SecTrustSetAnchorCertificatesOnly` (the test CA only, never the system store), an SSL policy for the host name, minimum TLS 1.2. The negotiated version comes from `NWProtocolTLS.Metadata`.

`prependApplicationProtocol` is public API with no availability limit, so it works on macOS 14. Placing TLS in the stack below a framer was not needed.

## Measured (Docker, Apple Silicon, debug build)

| Case | Result |
|---|---|
| PostgreSQL 17.12, test CA | TLS 1.3 on both sides (`pg_stat_ssl`), query answered, 48 ms incl. connect |
| MariaDB 11.8.9, test CA | TLS 1.3 on both sides (`Ssl_version`), query answered, 12 ms |
| Both, system trust only | rejected (`-9813` / `-9808`), no data sent |
| Both, server without TLS | framer fails the connection (`EPROTO`), no plaintext fallback |

## Rules for the real client (DBKit)

- Never fall back to plaintext when the server refuses TLS or lacks `CLIENT_SSL`; plaintext only as an explicit connection setting for local servers.
- Fail if any bytes follow the PostgreSQL `S` answer or the MySQL greeting before the TLS handshake (injected plaintext, as in CVE-2021-23214).
- The MySQL capabilities sent in the SSLRequest must equal those in the later HandshakeResponse41 (sequence 2).
- Authentication (SCRAM-SHA-256, `caching_sha2_password`, `mysql_native_password`) was out of scope; the spike used trust / empty root password.

## Reproduce

Certificates with `openssl` (CA + server certificate for `localhost`/`127.0.0.1`), containers `postgres:17` with `ssl=on` and `mariadb:11` with `--ssl-cert/--ssl-key`, the files copied in with `docker cp` (Docker Desktop does not share the temp folder). Then:

```
swift build --product TLSSpike
.build/debug/TLSSpike ca.der <pg-port> <mysql-port>
```
