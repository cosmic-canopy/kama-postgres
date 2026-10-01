# Roadmap

Where this is, 2026-09-30: the scaffold and the test server are done. Every compiler gap this package filed
is fixed upstream, as of kama 0.9.486 (see [KAMA_GAPS.md](../KAMA_GAPS.md)). The client is next.

Each phase ends green: `tools/test.sh`, and from phase 4 on, the integration suite on the whole server
matrix.

| # | phase | state |
|---|---|---|
| 0 | Scaffold; `tools/pg.sh` + server config + test PKI; language probes | **done** |
| 1 | `@kama/tls`: vendor Mbed TLS 4.1.1 LTS, `tls::version()` | next (in `../kama-tls`) |
| 2 | `@kama/tls`: `TlsStream<S>` over a memory BIO; in-memory and TCP loopback handshake matrix | |
| 3 | Pure layers: `protocol/` buffers + every message (golden bytes, malformed input); SCRAM/md5 over `std::digest` (RFC vectors); connection strings + `.pgpass` (libpq's URI regression cases); type codecs; generated SQLSTATE and OID tables | |
| 4 | Plain connection: startup, trust / password / md5 / SCRAM, simple query, errors, notices — first integration run | |
| 5 | Extended query: parameters and the `pg"…"` tag, `column::<T>` / `rowAs::<T>`, streaming, portals; type round-trips on 14–19 | |
| 6 | TLS through `@kama/tls`: SSLRequest and direct negotiation, every sslmode, verify-full, SCRAM-SHA-256-PLUS, client certificates | |
| 7 | Statement cache, transactions and savepoints, COPY, LISTEN/NOTIFY, pipelining, cancel and timeouts, Unix sockets, multi-host and `target_session_attrs`, keepalive | |
| 8 | Pool (cross-isolate), examples, hardening (server restart, bounded memory), CI green, docs | |
| — | Publish `@kama/tls` 0.1.0, then `@kama/postgres` 0.1.0 — only on the maintainer's word | |

## Decided, and why

- **Native protocol, not libpq.** Consumers install nothing, which is the rule every `@kama` package keeps,
  and the package controls binary codecs, pipelining, COPY and errors.
- **TLS is its own package.** kama's std declares TLS a non-goal. As in Rust, the database driver consumes a
  TLS package rather than embedding one.
- **Typed access is `column::<T>`, bounded on `Deserializable`.** Methods cannot be generic (a cstar
  decision), and a package cannot add a contract to `Uuid` or `Timestamp`. The serde contract is the one
  they already implement.
