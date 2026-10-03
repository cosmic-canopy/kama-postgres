# Roadmap

Where this is, 2026-10-03: phases 0–7 are done, and 0.2.0, which carries phase 7, is published (0.1.0 was phases 0–6, with `@kama/tls` 0.1.0). The client connects and queries on every supported server
(14–18, 19 beta), debug and release, in plaintext and over TLS:
- **Connecting.** It resolves its configuration exactly as libpq does: connection string, service file, PG*
  environment, password file, and require_auth. It tries each host and address within connect_timeout, over
  TCP or a Unix-domain socket (with `requirepeer`).
- **Authenticating.** Trust, password, md5 and SCRAM (with SASLprep, as PostgreSQL prepares a password) all
  work, and it refuses a server that has not proved it knows the password.
- **TLS.** Every sslmode with libpq's fallbacks, direct negotiation, verify-ca and verify-full (libpq's host-name
  rules), client certificates and encrypted keys, CRLs, `sslrootcert=system`, sslcertmode, protocol bounds,
  SCRAM-SHA-256-PLUS and `sslkeylogfile`, through `@kama/tls` (Mbed TLS). A `Dialer` opens each connection when a
  caller wants its own (a tunnel, a proxy).
- **Querying.**
  - The simple protocol, with libpq's error and notice formatting.
  - The extended protocol, with typed parameters and the `pg"…"` tag.
  - Prepared statements, chunked rows and portals.
  - Typed reads through `Deserializable`: `column::<T>`, `columnOpt::<T>` and `rowAs::<T>`, arrays of one
    dimension included. Every built-in type this client reads round-trips on every server version.
- **The full session (phase 7).**
  - A statement cache, which is pgx's design.
  - Transactions and savepoints, with a body helper that nests.
  - COPY in and out.
  - Waiting for notifications.
  - libpq's pipeline mode, with pgx's Batch on top.
  - Cancel requests (libpq 17's, encrypted), and query timeouts that cancel and keep the connection.
  - `target_session_attrs` against a real hot standby, and `load_balance_hosts=random`.

Expected values come from PostgreSQL itself: its TAP tests and test modules, a live libpq asked case by case, and a
live server's send and output functions. For TLS that is `005_negotiate_encryption.pl`'s 53 negotiation cases (replayed
event by event against a scripted server), `001_ssltests.pl`'s 36 host-name cases with upstream's certificates, and 43
cases the container's libpq answered against the same server and files. Phase 5's gaps (KPG-23 to KPG-30) were fixed in
0.9.519, and phase 6's (KPG-31, a file's owner, and KPG-32, `break` in a `match` arm) in 0.9.521 and 0.9.522; the
package needs the 0.9.523 release that carries them ([KAMA_GAPS.md](../KAMA_GAPS.md)). Phase 7's tests replay the traces
of libpq's `libpq_pipeline` message for message and the cases of `001_stream_rep.pl` and `003_load_balance_host_list.pl`,
and ask the container's libpq about each `target_session_attrs` case against a primary and its standby. Phase 8 is next.

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
| 6 | TLS through `@kama/tls`: SSLRequest and direct negotiation, every sslmode, verify-full, SCRAM-SHA-256-PLUS, client certificates, CRLs, `sslkeylogfile`; the integration suite on 14–19 plaintext and over TLS | **done** |
| 7 | Statement cache, transactions and savepoints, COPY, waiting for LISTEN/NOTIFY, pipelining and batches, cancel and query timeouts, `target_session_attrs` and `load_balance_hosts` | **done** (0.2.0, published 2026-10-03) |
| 8 | Pool (cross-isolate), examples, hardening (server restart, bounded memory), CI green, docs | next |
| — | Publish `@kama/tls` 0.1.0, then `@kama/postgres` 0.1.0, its `@kama/tls` dependency switched from the path to that version | **done** (2026-10-02) |

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
- **TLS runs over any `Transport`,** as pgx runs it over whatever its DialFunc returns and tokio-postgres over any
  stream. So `connectOver` and `connectWith` (a `Dialer` per connection) get TLS too, and the unit tests run real TLS
  against a scripted server with no network.
- **libpq's words, Mbed TLS's reasons.** Where libpq quotes OpenSSL ("SSL error: %s"), this client prints libpq's
  frame with @kama/tls's words, which say what failed (the alert's name, the verify reasons). No other driver
  reproduces another library's wording, and OpenSSL's changes between its versions.
- **The host name is checked by libpq's rules, not the TLS library's:** Mbed TLS verifies the chain only, and
  `postgres::verifyServerName` ports libpq's check (subjectAltNames of the host's kind before the CN, one-label
  wildcards, its messages). SNI is libpq's too: a host name, never an address, and not with `sslsni=0`.
- **A `TlsConfig` per attempt,** as libpq builds an SSL_CTX per connection: every file is read again, and a bad key
  fails that attempt (so `prefer` falls back), not the configuration.
- **Typed access is `column::<T>(rows:, row:, index:)`, bounded on `Deserializable`.** Methods cannot be generic
  (a cstar decision), and a package cannot add a contract to `Uuid` or `Timestamp`. The serde contract is the one
  they already implement. It is addressed as `PQgetvalue(res, row, col)` is: a row does not carry the column
  descriptions, so `Rows` holds no `Shared` and stays `Sendable`.
- **One result type, `Rows`, for both protocols**, as libpq's PGresult is.
- **Describe first.** A query is parsed and described, then bound and executed. Each parameter is sent as the
  type the server inferred, and each column of a type this client reads in binary is asked for in binary, so
  every column can be read as text. The statement cache removes the extra round trip once a query is known.
- **Parameters are `PgParam`s**, a contract this package declares, with `type adapter`s for the types it does not
  own. Each writes itself through a `Serializer`. A value is binary when it is its type's own kind, and text
  otherwise, which the server's input function reads. So a `Uuid`, a `Timestamp` and a `Numeric` need no special
  case, and the server reports a value it refuses in its own words. std's `SqlParam` is too narrow for a driver
  (no arrays, UUIDs or timestamps), as its own comment says.
- **The `pg` tag's holes are typed** (`Template<PgParam>`), so each is checked where the string is written, and an
  empty Optional hole is NULL.
- **An integer reads into a type at least as wide as its column's, never narrower**, so whether a read succeeds
  never depends on the data.
- **The statement cache is pgx's.** It keeps an LRU of named statements, on by default, with a describe-only mode for
  poolers and an off mode. A plan the server refuses after a schema change is retried once outside a transaction, as
  pgjdbc does. libpq has no cache, so this follows the drivers that have one.
- **Transactions are methods plus a body.** `transaction(body:)` runs a `TransactionBody`, which nests as a savepoint,
  because kama has no closures. The request for an exit hook on a borrow window is KPG-35. Once it lands, this
  becomes `borrow conn.transaction() as tx { … }`.
- **Pipelining is libpq's pipeline mode, ported step by step,** with a pgx-style `Batch` on top. Its tests are libpq's
  own traces.
- **A query timeout cancels and keeps the connection,** as Npgsql, pgjdbc and asyncpg do:
  - when the limit passes, it sends a cancel;
  - it waits a grace period for the server's 57014;
  - it closes the connection only if the grace passes.

  libpq has no client-side timeout to port.
- **One reader.** Every result goes through `Connection.readRows`, which reads from a queue of the commands sent, as
  libpq's PGcmdQueueEntry does. So a pipeline, a cached statement and a plain query share the check of each
  message's place.
