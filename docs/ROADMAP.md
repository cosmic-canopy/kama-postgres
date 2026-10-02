# Roadmap

Where this is, 2026-10-01: phases 0–5 are done. The client connects and queries on every supported server
(14–18, 19 beta), debug and release:
- **Connecting.** It resolves its configuration exactly as libpq does: connection string, service file, PG*
  environment, password file, and require_auth. It tries each host and address within connect_timeout, over
  TCP or a Unix-domain socket (with `requirepeer`).
- **Authenticating.** Trust, password, md5 and SCRAM (with SASLprep, as PostgreSQL prepares a password) all
  work, and it refuses a server that has not proved it knows the password.
- **Querying.**
  - The simple protocol, with libpq's error and notice formatting.
  - The extended protocol, with typed parameters and the `pg"…"` tag.
  - Prepared statements, chunked rows and portals.
  - Typed reads through `Deserializable`: `column::<T>`, `columnOpt::<T>` and `rowAs::<T>`, arrays of one
    dimension included. Every built-in type this client reads round-trips on every server version.

Expected values come from PostgreSQL itself: its TAP tests and test modules, a live libpq asked case by case, and a
live server's send and output functions. Phase 5 began with the port to kama 0.9.506, which fixed every gap phases 3
and 4 filed (KPG-11 to KPG-22). Its own gaps, KPG-23 to KPG-30, were fixed in 0.9.519, and the package now needs that
compiler: the `pg` tag's holes are typed, and every workaround is gone ([KAMA_GAPS.md](../KAMA_GAPS.md)). Phase 6,
TLS, is next. It needs `@kama/tls` ported to the new `IoError` first.

Each phase ends green: `tools/test.sh`, and from phase 4 on, the integration suite on the whole server
matrix.

| # | phase | state |
|---|---|---|
| 0 | Scaffold; `tools/pg.sh` + server config + test PKI; language probes | **done** |
| 1 | `@kama/tls`: vendor Mbed TLS 4.1.1 LTS, `tls::version()` | **done** (`../kama-tls`) |
| 2 | `@kama/tls`: `TlsStream<S>` over a memory BIO; in-memory and TCP loopback handshake matrix | **done** (`../kama-tls`) |
| 3 | Pure layers: `protocol/` buffers + every message (golden bytes, malformed input); SCRAM/md5 over `std::digest` (RFC vectors); connection strings (libpq's URI regression cases); type codecs; generated SQLSTATE and OID tables | **done** |
| 4 | Plain connection: Config as libpq resolves it (service file, environment, `.pgpass`, `require_auth`, every setting checked); hosts and addresses in order with `connect_timeout` and keepalive; Unix-domain sockets and `requirepeer`; startup, trust / password / md5 / SCRAM, protocol 3.2 negotiation; simple query, errors, notices, notifications queued; `Transport` for a caller's own stream — integration suite on 14–19 | **done** |
| 5 | Extended query: parameters and the `pg"…"` tag, `column::<T>` / `rowAs::<T>`, streaming, portals; type round-trips on 14–19 | **done** |
| 6 | TLS through `@kama/tls`: SSLRequest and direct negotiation, every sslmode, verify-full, SCRAM-SHA-256-PLUS, client certificates | next |
| 7 | Statement cache, transactions and savepoints, COPY, waiting for LISTEN/NOTIFY, pipelining, cancel and query timeouts, `target_session_attrs` and `load_balance_hosts` | |
| 8 | Pool (cross-isolate), examples, hardening (server restart, bounded memory), CI green, docs | |
| — | Publish `@kama/tls` 0.1.0, then `@kama/postgres` 0.1.0 — only on the maintainer's word | |

## Decided, and why

- **Native protocol, not libpq.** Consumers install nothing, which is the rule every `@kama` package keeps,
  and the package controls binary codecs, pipelining, COPY and errors.
- **TLS is its own package.** kama's std declares TLS a non-goal. As in Rust, the database driver consumes a
  TLS package rather than embedding one.
- **Configuration is libpq's, and so are the messages.** A connection string, environment and password file
  mean here what they mean to psql. Every setting is honoured or refused with a clear error, never ignored.
  The expected values in the tests come from libpq: PostgreSQL's TAP tests, and the container's libpq asked
  live.
- **The socket is non-blocking, driven by a poller with deadlines,** as libpq drives it. That is what
  `connect_timeout` needs now, and what query timeouts, cancellation and pipelining will need later. The
  `Transport` contract keeps TCP, Unix sockets and TLS (phase 6) out of `Connection`.
- **Stricter than libpq where libpq is lenient by default.** Once SCRAM starts, AuthenticationOk before a
  verified server signature is refused, whatever `require_auth` says. Out-of-order SASL messages are a protocol
  error.
- **Typed access is `column::<T>(rows:, row:, index:)`, bounded on `Deserializable`.** Methods cannot be generic
  (a cstar decision), and a package cannot add a contract to `Uuid` or `Timestamp`. The serde contract is the one
  they already implement. It is addressed as `PQgetvalue(res, row, col)` is: a row does not carry the column
  descriptions, so `Rows` holds no `Shared` and stays `Sendable`.
- **One result type, `Rows`, for both protocols**, as libpq's PGresult is.
- **Describe first.** A query is parsed and described, then bound and executed. Each parameter is sent as the
  type the server inferred, and each column of a type this client reads in binary is asked for in binary, so
  every column can be read as text. The statement cache (phase 7) removes the extra round trip.
- **Parameters are `PgParam`s**, a contract this package declares, with `type adapter`s for the types it does not
  own. Each writes itself through a `Serializer`. A value is binary when it is its type's own kind, and text
  otherwise, which the server's input function reads. So a `Uuid`, a `Timestamp` and a `Numeric` need no special
  case, and the server reports a value it refuses in its own words. std's `SqlParam` is too narrow for a driver
  (no arrays, UUIDs or timestamps), as its own comment says.
- **The `pg` tag's holes are typed** (`Template<PgParam>`), so each is checked where the string is written, and an
  empty Optional hole is NULL.
- **An integer reads into a type at least as wide as its column's, never narrower**, so whether a read succeeds
  never depends on the data.
