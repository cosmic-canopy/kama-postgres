# Roadmap

Where this is, 2026-10-18: phases 0–7 are done, and phase 8 is under way (S0 and S0b are done). 0.2.0 carried phase 7, and 0.2.1 is 0.2.0 on kama 0.9.667 (published). S0b's scoped transactions are a breaking change, unreleased until 0.3.0. 0.1.0 was phases 0–6, with `@kama/tls` 0.1.0. The client connects and queries on every supported server
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
  - Transactions and savepoints, scoped by a borrow window that nests (since phase 8's S0b).
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
and ask the container's libpq about each `target_session_attrs` case against a primary and its standby. On kama 0.9.667,
KPG-33 to KPG-38 are fixed. KPG-39 (fixed in 0.9.669) and KPG-40 (nesting through `tx.conn()` is intended; the freeze
it relies on was fixed in 0.9.672) wait for the v0.9.672 release. Phase 8 is under way: its plan is below.

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
| 8 | Scoped transactions; pool (cross-isolate, with maintenance); hardening (server restart, bounded memory, hostile input); examples; docs. Ends at 0.3.0 | in progress: S0 (0.2.1) and S0b done; S1 next |
| 9 | Windows: libpq's WIN32 branches, a Windows CI leg | |
| — | Publish `@kama/tls` 0.1.0, then `@kama/postgres` 0.1.0, its `@kama/tls` dependency switched from the path to that version | **done** (2026-10-02) |

## Phase 8, planned

Decided with the maintainer on 2026-10-18. Each step commits on main once it is green: `tools/test.sh`, debug and
release, and the integration matrix (14–19, debug, release and TLS). Before a test is called good, a mutation must make
it fail.

- **S0, done (0.2.1).** The port to kama 0.9.667.
- **S0b, done: scoped transactions** (KPG-35 is fixed in 0.9.658: a view's `~dtor` closes its borrow window).
  - The shape is `borrow conn.transaction() as tx { … }`. It was prototyped on 0.9.667, nesting and an early return
    included.
  - `Connection` implements a `@viewable` contract whose nullary mint `transaction()` sends BEGIN, or SAVEPOINT inside
    an open transaction.
  - The `Transaction` view offers:
    - `conn()`, a `ref Connection`, since the host is frozen inside the window;
    - `commit()`;
    - `rollback()`;
    - `began()`, BEGIN's outcome, since a mint cannot return a Result;
    - `setOptions(options:)`, which runs SET TRANSACTION before any query.
  - `~Transaction` rolls back, or does ROLLBACK TO and RELEASE for a savepoint, unless the server says the transaction
    is already over. So a commit made through `tx.conn()` counts.
  - It **replaces** `transaction(body:, options:)` and `TransactionBody` in 0.3.0. That is a breaking change, made
    because there is one way to do a thing, and kama has no overloading, so both cannot be called `transaction`.
    `begin`, `commit`, `rollback` and the savepoint methods stay.
  - As built: a view holds no resource, so `began()`'s error waits on the `Connection` (which is why `PgError` became
    `Sendable`, on `@kama/tls` 0.1.3). "The server says it is over" is a count of ReadyForQuery's returns to idle,
    taken as the window opens. A window that cannot roll back closes the connection, as pgx's Rollback does.
    `setOptions` on a savepoint is the server's to take (READ ONLY) or refuse (an isolation level, 25001), which fails
    the savepoint only.
- **S1, connection groundwork.**
  - `Connection.ping()`: an empty query, with ReadyForQuery back.
  - `Connection.resetSession()`: Npgsql's reset, read from its pinned source and not typed from memory. The source is
    Npgsql v10.0.3 (2026-05-27, the latest release on 2026-10-18), `src/Npgsql/Internal/NpgsqlConnector.cs` (SHA256
    `7a13d79578e0a0874c5842532d450d496f7d52c0f66d3fa7c1a2984a83465274`), `GenerateResetMessage()` and `Reset()`.
    What it says:
    - **The statements**, in this order and in one message: `SET SESSION AUTHORIZATION DEFAULT;RESET ALL;CLOSE ALL;
      UNLISTEN *;SELECT pg_advisory_unlock_all();DISCARD SEQUENCES;DISCARD TEMP`. The list this bullet held before was
      in another order.
    - **The gates:** each statement after the first two depends on the server's version (`Supports*` in
      `src/Npgsql/Internal/NpgsqlDatabaseInfo.cs`, SHA256 `5483a434b61c705dbfc6bff23267b1472063864fa4a6e1c901b34b0d5d07832d`;
      Redshift's in `src/Npgsql/PostgresDatabaseInfo.cs`, SHA256
      `5cbf08c0a67e6ae68751b573c821a7eddf8fc12a1507fe102c65537697cb8656`). Every gate holds on 14–19.
    - **With nothing prepared**, Npgsql sends `DISCARD ALL` instead, which also deallocates. Here the statement cache
      and `prepare()` keep named statements, so S1 decides when nothing is prepared, and must empty the cache along
      with a `DISCARD ALL`.
    - **A transaction block is rolled back first**, since `DISCARD ALL` cannot run inside one. `Connection.settle()`
      (S0b) is that rollback.
    - **It costs Npgsql no round trip:** `PrependInternalMessage` sends the reset in front of the connection's next
      command. The decision below says "one round trip", so S1 decides between prepending it, as Npgsql does, and
      sending it on release.
    - Fetch the three files again by script and check their hashes; do not trust this summary over them.
  - Whatever state the pool needs in order to decide what to do on release.
- **S2, hardening.**
  - libpq's rule that a message of a short type over 30000 bytes is "lost synchronization with server" (fe-protocol3.c).
  - Bounds, each configurable: the read buffer that grows while a write waits, the notification queue, the
    ParameterStatus count, and an optional limit on a buffered result (off by default).
  - `tools/pg.sh restart|stop|start`, and restart tests, with libpq's words, over TLS too.
  - Seeded mutations of every scripted reply. Each must end in a `PgError`, never a panic.
- **S3, the pool** (`src/pool/`).
  - **Shape.** One `Channel<Slot>` (`Idle(conn, since, born)` or `Empty`) plus a permit channel. That bounds the total
    with no atomic and no mutex, and lets a sequential user keep one connection.
  - **API.**
    - `Pool.make(config:, options:)`.
    - `pool.share()` gives a Sendable `PoolShare`, which `Pool.join(share:)` turns into a pool in another isolate.
    - `acquire(timeout:)` gives a `Lease`, which returns its connection on drop.
    - `run(body:)`.
  - **Defaults** are pgxpool's: max size max(4, cpus), min idle 0, a lifetime of 1 h with jitter, an idle timeout of
    30 min, and a health check every minute. The acquire timeout is 30 s, as sqlx and HikariCP use.
  - **Release.** A closed, busy, COPY or pipeline connection is closed. One inside a transaction is rolled back, then
    reset (decision below).
    - `Connection.settle()` (S0b) is the rollback half: it reads off an open result, sends ROLLBACK, and closes a
      connection still in a block. Release must check `pipelineStatus()` itself, because `transactionStatus()` says
      Idle in pipeline mode once the queue drains.
    - `borrow lease.conn().transaction() as tx` compiles over a lease whose `fn ref Connection conn()` returns
      `this.slot[0]` (probed on 0.9.667).
- **S4, maintenance.** One isolate per pool, stopped when the pool drops. It closes idle and expired connections, pings
    the rest, and keeps min idle. Acquire also pings a connection that has been idle for more than 1 s.
- **S5, pool tests.**
  - Unit, through a counting Dialer: the bound, timeouts, replacement, the reset's exact messages, reaping.
  - Integration: N isolates (`pg_stat_activity` never over the maximum), a server restart, TLS.
- **S6, examples.** `examples/<name>/`, each its own executable project, as in @kama/sodium: quickstart, typed rows,
  transactions, COPY from a CSV file, a LISTEN/NOTIFY worker, a pool shared by isolates, a batch. `tools/test.sh`
  builds them; `tools/test-integration.sh` runs them live.
- **S7, docs and 0.3.0.**
  - Make the README's links absolute, because the registry renders a relative link as plain text.
  - Update the CHANGELOG, this file and AGENTS.postgres.md.
  - Tag `v0.3.0` for the registry to publish.

**Decisions:**
- **On release, roll back and reset the session.** Npgsql and asyncpg do; pgx and deadpool do not. It is the safer
  default and costs one round trip. A pool can turn it off.
- **A maintenance isolate.** pgxpool, HikariCP, Npgsql, sqlx and bb8 all have one.
- **Windows is phase 9.**
- **Phase 8 ends at 0.3.0, not 1.0.0.** kama is pre-1.0, Windows is not done, and the first users of the pool may ask
  for changes.

**What the next session needs to know** (written 2026-10-18, at the end of S0b):
- **Where it stands.** S0 and S0b are done. The working tree is clean, and main is 4 commits ahead of origin: @kama/redis's
  handshake fix (`bacbcc4`), the `@kama/tls` ^0.1.3 floor with `Sendable` errors (`201ada9`), S0b (`33bde18`), and
  KPG-39/KPG-40's answers (`05e8031`), plus the commit that wrote this. Nothing is pushed: pushing waits for the
  maintainer.
- **First: port to kama v0.9.672, once it is tagged.** It was not tagged on 2026-10-18 (the latest release was v0.9.667):
  check `https://api.github.com/repos/cosmic-canopy/kama/releases`. If it is still not out, start S1 on 0.9.667 and port
  when it lands.
  - **KPG-40, answered:** `borrow tx.conn().transaction() as inner` is intended. Keep it, and add no mint on the view.
    Before 0.9.672 the inner window did not freeze `tx`, so the outer transaction could be committed from inside a
    savepoint. The windows' check of the server's status made that harmless, but 0.9.672 refuses it.
  - **KPG-39, fixed in 0.9.669:** std's JSON can be imported beside this package.
  - **The floor:** raise `"kama"` to `>=0.9.672` in the three manifests and in both `KAMA_VERSION` pins of
    `.github/workflows/ci.yml`. That is the recommendation put to the maintainer, who had not answered yet: 0.3.0 is
    unreleased, and 0.9.672 is the first compiler that refuses `tx` inside `inner` and lets JSON be imported. Confirm
    it before raising.
  - Steps:
    1. Download the release and check its checksum.
    2. Run both entries' repros and the refusal of `tx` inside `inner`, and move both entries to FIXED.
    3. Raise the floor.
    4. Add a `JsonValue` test beside `typed_test.kama`'s `Untyped`.
    5. Drop the README's known issue, and note it all in the CHANGELOG.
    6. Run the full gate.
- **Then S1**, as its bullet above says, with the facts it records from Npgsql's source.
- **The gate, per step:**
  - `tools/test.sh`, which runs the unit suite in debug and release;
  - `tools/test-integration.sh`, on 14–19 in debug, release and TLS;
  - **`tools/mutate.sh tools/mutations/<step>.json --version 18`**. This runs each mutation in a copy of the tree and
    exits 1 unless every one makes its targeted case fail. S0b's 26 are in `tools/mutations/s0b.json`. Write a file per
    step, and re-run older files when their code changes. A `BAD-PATTERN` means the source moved on, so update the
    mutation.
- **The compiler.** Build with a release, as CI does. The dev tree (`../cstar/out`) is past the release, and
  `~/.kama/bin/kama` is an old 0.9.440.
  - To get one: `kama-macos-universal-vX.tar.gz` from the `cosmic-canopy/kama` GitHub release, checked against its
    `.sha256` and unpacked anywhere (it holds `kama-macos-universal-vX/bin/kama`).
  - Run with `KAMA=<that>/bin/kama tools/test.sh`, or `curl -fsSL https://kama-lang.org/install.sh | KAMA_VERSION=vX sh`.
  - **The editor's diagnostics come from that old 0.9.440 language server.** It rejects a view's `~dtor` and cannot
    resolve this package's imports, so ignore it and trust `kama check`.
- **kama-tls.** `../kama-tls` is readable again. The package needs `@kama/tls` ≥ 0.1.3 (its `TlsError` is `Sendable`),
  and the locks pin 0.1.4. kama-tls is busy with its own roadmap, so ask the maintainer before you need something there.
- **The servers.** `kama-pg-14` to `kama-pg-19` and their standbys are running under podman (`tools/pg.sh`).
- **Other sessions commit here.** @kama/redis's session committed `bacbcc4` to this repo during S0b. Read `git status`
  and `git log` before committing, and stage only your own files.

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
- **A transaction is a borrow window,** `borrow conn.transaction() as tx { … }`, psycopg's `with conn.transaction()`
  with no closure. The window rolls back unless the transaction is over, on every path out of the block, and a window
  inside a window is a savepoint. It replaced 0.2's `transaction(body:)` once KPG-35 gave a view a destructor that
  runs as its window closes.
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
