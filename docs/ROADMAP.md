# Roadmap

Where this is, 2026-10-20: phases 0–7 are done, and phase 8 is under way (S0, S0b, S1, S2 and S3 are done, and the port to kama 0.9.673). 0.2.0 carried phase 7, and 0.2.1 is 0.2.0 on kama 0.9.667 (published). S0b's scoped transactions are a breaking change, unreleased until 0.3.0. 0.1.0 was phases 0–6, with `@kama/tls` 0.1.0. The client connects and queries on every supported server
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
KPG-33 to KPG-38 are fixed. KPG-39 (std's JSON beside this package) and KPG-40 (nesting through `tx.conn()` is intended,
and the freeze it relies on is fixed) were verified on the 0.9.673 release, which the package now needs. KPG-41 (on
macOS, a release build with `std::process` beside `std::concurrent` fails in clang) is open, found in S2c, with a
workaround in the integration tests only. Phase 8 is under way: its plan is below.

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
| 8 | Scoped transactions; pool (cross-isolate, with maintenance); hardening (server restart, bounded memory, hostile input); examples; docs. Ends at 0.3.0 | in progress: S0 (0.2.1), S0b, S1, the port to kama 0.9.673, S2 and S3 done; S4 next |
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
- **S1, done: connection groundwork.**
  - `Connection.ping()`: an empty query, with ReadyForQuery back. A result in its answer ends the session.
  - `Connection.resetSession()`: Npgsql's reset, in `src/session/reset.kama`.
    - **Its source:** Npgsql v10.0.3 (2026-05-27, commit `d3768398c178`), four files pinned by SHA256:
      - `src/Npgsql/Internal/NpgsqlConnector.cs` (`7a13d795…3274`): `GenerateResetMessage()` and `Reset()`;
      - `NpgsqlDatabaseInfo.cs` (`5483a434…832d`) and `PostgresDatabaseInfo.cs` (`5cbf08c0…8656`): the gates;
      - `PregeneratedMessages.cs` (`b60ae0c5…b6a3`): the texts of DISCARD ALL and ROLLBACK.

      `tools/gen-reset-vectors.sh` reads them into the unit tests' expected texts (`tests/unit/src/reset_vectors.kama`).
    - **The statements**, in one Query: `SET SESSION AUTHORIZATION DEFAULT;RESET ALL;CLOSE ALL;UNLISTEN *;SELECT
      pg_advisory_unlock_all();DISCARD SEQUENCES;DISCARD TEMP`.
    - **The gates** are Npgsql's:
      - CLOSE ALL and DISCARD TEMP from 8.3;
      - UNLISTEN from 6.4;
      - the advisory unlock from 8.2;
      - DISCARD SEQUENCES from 9.4;
      - nothing at all below 8.3.

      Redshift's UNLISTEN check is not ported: Npgsql's own comment says it is never used.
    - **With nothing prepared, it sends DISCARD ALL**, whose tag empties the cache (`noteTag`). "Prepared" means a named
      statement in the cache, or a `prepare()` not closed (`statementsOpen`, which may count high but never low).
    - **A block is rolled back first**, with ROLLBACK and the reset as two Query messages in one write. PostgreSQL 18.4
      refuses `ROLLBACK;DISCARD ALL` in one Query ("DISCARD ALL cannot run inside a transaction block").
    - **It is sent at once, not prepended** (see the decision below). A failure closes the connection, as Npgsql's
      Break does. A server that reported no `server_version` is refused.
    - **Queued notifications are dropped.** The notice handler and the query timeout stay as they are: the pool
      restores its own (S3).
  - **What release reads is already public:**
    - `isClosed()`;
    - `pipelineStatus()`;
    - `transactionStatus()`, which is Active while a result, a chunked stream or a COPY is open.

    The unit tests pin each one (the "release:" cases in `tests/unit/src/reset_test.kama`).
  - **Mutations:** `tools/mutations/s1.json`, 25 unit and 10 integration. The integration ones remove each statement of
    the long form in turn, and each removal fails a live check.
- **The port to kama 0.9.673, done (2026-10-19).** No v0.9.672 was tagged, so 0.9.673 is the first release with
  KPG-39's and KPG-40's fixes, and the floor is `>=0.9.673` (the maintainer approved the raise to the first release with
  them).
  - Both entries' repros ran as filed. The refusal of `tx` inside `inner` was checked, and both entries moved to FIXED.
  - `typed_test.kama`'s `jsonValueTests` reads a column and a row into std's `JsonValue`. That program fails to build
    on 0.9.667.
  - The README's known issue is gone.
- **S2, hardening**, in four commits, in this order (planned with the maintainer on 2026-10-19):
  - **S2a, done: libpq's checks on a message header.** `frame(buf, framing)` checks a header as libpq does where it
    is read (`Framing::Startup`, `Session`, `CopyOut`), on the header alone:
    - in a session, a length under 4, or over 30000 for a type outside `VALID_LONG_MESSAGE_TYPE`, is "lost
      synchronization", and during COPY OUT a ParameterStatus may be long (getCopyDataMessage);
    - before authentication, only R, E and v, checked on the first byte, R and v within 8–2000 bytes, and an E outside
      8–30000 bytes read as a pre-3.0 error's text.

    `tools/gen-libpq-tables.sh` reads the types, limits and messages from the pinned fe-protocol3.c, fe-connect.c and
    protocol.h (`src/protocol/framing.kama`), and works out libpq's outcome for every type and length in each place
    (`tests/unit/src/framing_vectors.kama`). The buffer grows only as bytes arrive. Live: PostgreSQL 18 reports
    `search_path`, and one over 30000 bytes loses synchronization here as it does in psql.
  - **S2d, done: seeded mutations of every scripted reply** (`tests/unit/src/garble_test.kama`). Eighteen conversations
    carry every backend message in each state; each reply in turn is changed ten ways (`GarbleKind`), seeded, through
    `FakeServer.garbled`. A run must end in a result or a `PgError` with a message, never a panic, and a protocol error
    must end the session. It found one thing to fix: a pre-3.0 error with an empty text, now "received invalid error
    message". 500 seeds (a million cases, 80 seconds in release) find nothing more.
  - **S2b, done: bounds, each configurable** (`Limits`, `Config.setLimits`; each an `Optional`, None turning it off):
    - `readBuffer`, the bytes held while a write waits (1 GiB): past it the connection closes;
    - `parameters` (1,000): past it the connection closes;
    - `notifications` (10,000): the oldest dropped, counted and logged, decided with the maintainer although no other
      driver bounds this queue;
    - `resultBytes` (off): the rest read and dropped, the call failing with `PgError::Limit`, and the session and its
      transaction kept, where pgjdbc master closes the connection. A simple query's statements and a batch's results
      count together.

    Live: a result over the bound and a burst of notifications against each server. The garbling runs half its cases
    under tiny bounds.
  - **S2c, done: server restarts.**
    - `tools/pg.sh stop|start|restart`: a fast shutdown, PGDATA kept; `up` starts a stopped server again.
    - A session's I/O failure is `PgError::Lost`, in libpq's words (pqsecure_raw_read, pqsecure_raw_write,
      pqSocketCheck), where a plain socket used to print the OS's words ("Broken pipe"). After a failed write, what the
      read finds is reported first, as libpq reads on after one.
    - `tests/integration/src/restart_test.kama`, a leg of its own per version (`PGTEST_RESTART=1`): sessions across a
      restart (plaintext, TLS, in a block, with a cached statement, a command in flight, `ping`, `resetSession`), a
      connect while the server is down (libpq's refusal, word for word; a host list goes on to the standby), connects
      every 250 ms while it starts, and sessions after it. Asked across a restart from the standby's container, the
      server's psql printed the FATAL, then "server closed the connection unexpectedly…" (or "SSL connection has been
      closed unexpectedly" over TLS). This client reports the FATAL, as it did before for a terminated backend.
    - **KPG-41** (open): on macOS a release build with `std::process` beside `std::concurrent` fails in clang. The
      restart group is `file @compileFor(!RELEASE)`, with a release twin (`restart_release.kama`), and the leg runs the
      debug build. Delete both when it is fixed.

- **S3, done: the pool** (`src/pool/`, `postgres::pool`).
  - **Shape, as planned:** two bounded channels of `maxSize`, `slots` (`Idle(conn, expires)` or `Empty`) and
    `permits` (filled at the start). Acquire takes an idle connection, else a permit (and connects), else waits on
    `slots` until `acquireTimeout`. Freed capacity goes into `slots` as `Empty`, never back to `permits`, so a waiter
    wakes for it. No lock, no atomic; a sequential user keeps one connection.
  - **API, as built:**
    - `Pool.make(config:, options:)`, and `Pool.makeWith(connector:, config:, options:)` with a `Connector`
      (`open(config:)`, `fork()`), the seam for the unit tests and for a `Dialer`.
    - `pool.acquire()` → `Lease`; `lease.conn()` is a `ref Connection`, which feeds a `ref Connection` parameter and
      a `borrow … transaction() as tx` window.
    - `pool.share()` → `PoolShare` (`Sendable`); `Pool.join(share: ref)` in another isolate. Only the pool that made
      the channels can share: only a `Channel` makes new ends for itself. A joined pool's `share()` is `Usage`.
    - `PoolOptions` (`Limits`' pattern): `maxSize`, `lifetime`, `lifetimeJitter`, `acquireTimeout`, `reset`,
      `queryTimeout`, `queryGrace`. Only what S3 honours; S4 adds its own.
    - `PgError::PoolTimeout`, sqlx's words.
  - **Decided while building (2026-10-19):**
    - **No `run(body:)`.** The lease gives its connection back on every path out of its scope, so a body-taking form
      would be a second way to do one thing, as `transaction(body:)` was.
    - **`acquire()` takes no timeout:** it is pool policy (`acquireTimeout`), as HikariCP and sqlx have it.
    - **Lifetime jitter defaults to 90 s**, HikariCP's 2.5% of the hour (pgxpool's default is none), so connections
      made together are not all replaced together.
  - **Release, as built:** closed, busy (Active), pipeline mode or past its lifetime → closed and `Empty`. Otherwise the
    pool's query timeout is put back (so it bounds the reset), the notice handler cleared, and `resetSession()` run (or,
    reset off, `settle()` when not Idle, through a `friend` grant). A connection that ends up closed → `Empty`.
  - **Tests:**
    - Unit (`tests/unit/src/pool_test.kama`): `ScriptConnector` opens each connection over the next script, so every
      message a release sends is checked. The cases are the bound and the timeout, a waiter in another isolate woken by
      a release, each kind of busy connection, the rollback and reset, the reset off, a failed reset, a failed connect,
      both lifetimes, the settings put back, and the refusals.
    - Integration (`tests/integration/src/pool_test.kama`), plaintext and TLS: the reset seen live (settings, temporary
      tables, advisory locks, LISTEN, prepared statements), a transaction left open seen aborted (`pg_xact_status`),
      and four isolates sharing a pool of 2, each seeing at most 2 sessions in `pg_stat_activity`.
    - Mutations: `tools/mutations/s3.json`.
- **S4, maintenance.** One isolate per pool, stopped when the pool drops. It closes idle and expired connections, pings
    the rest, and keeps min idle. Acquire also pings a connection that has been idle for more than 1 s.
- **S5, pool tests.**
  - Unit, through `ScriptConnector` (S3's): what S3's cases leave, and reaping.
  - Integration: S3 has N isolates under the bound and TLS; S5 adds a server restart, in the restart leg.
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
- **The reset is sent as the connection is released, not in front of its next command** (decided 2026-10-18, in S1).
  Npgsql prepends it, which saves the round trip. But a reset that fails would then surface on the next user's command,
  after that command had been sent and possibly run. Sent at once, a failure is the releaser's, and the pool closes the
  connection. asyncpg, and pgbouncer's `server_reset_query`, also reset before the connection is used again.
- **A maintenance isolate.** pgxpool, HikariCP, Npgsql, sqlx and bb8 all have one.
- **Windows is phase 9.**
- **Phase 8 ends at 0.3.0, not 1.0.0.** kama is pre-1.0, Windows is not done, and the first users of the pool may ask
  for changes.

**What the next session needs to know** (written 2026-10-20, after S3):
- **Where it stands.** S0, S0b, S1, S2 and S3 are done, and so is the port to kama 0.9.673. Nothing is pushed: pushing
  waits for the maintainer.
- **First: the next kama release, which is a port, not just a version.** cstar's tree (0.9.690 on 2026-10-20) carries:
  - KPG-41's fix (`fce00971`, 0.9.677);
  - KR-214 (0.9.680): a `Result` in statement position is refused, `_ = expr;` is the one explicit discard, and
    channels return `Result` (`send` → `Result<Unit, Undelivered<T>>`, `tryRecv`/`recvTimeout` →
    `Result<T, RecvError>`; `SendResult` and `RecvResult` are gone);
  - `main` returns the platform's exit status (0.9.681, 0.9.684): `fn int32 main()` is refused, `fn uint8 main()` it is;
  - a value a statement discards is dropped at the statement's end (0.9.676).

  Checked against that tree before the release, the package had 10 errors, the unit tests 16 and the integration tests
  13 at the first stage (the channel types and `main`), and more may follow once those clear. The maintainer approved
  raising the floor to the first release with KPG-41's fix (2026-10-19). The port is one commit:
  - run KPG-41's repro (`c3.kama`) with `--release` and move the entry to FIXED;
  - delete the workaround: `restart_test.kama`'s `file @compileFor(!RELEASE)`, `restart_release.kama`, and the
    debug-only restart leg in `tools/test-integration.sh`;
  - port the channel calls: the pool's are all in `Ends` (`src/pool/pool.kama`); the tests' are spread across
    `tests/*/src`;
  - raise `"kama"` in the three manifests, `KAMA_VERSION` in ci.yml, and the floor in AGENTS.postgres.md and the
    README, whose examples' `main` also changes;
  - the whole gate, with every mutation file (s0b, s1, s2, s3), since 0.9.676 changes when values drop.
- **Next: S4, maintenance**, as its bullet above says. What S3 leaves for it:
  - `PoolOptions` gets `minIdle`, `idleTimeout` (30 min) and `healthCheck` (1 min) then, and `Slot::Idle` gets a
    `since`.
  - The maintenance isolate needs its own ends of the channels: `Factories.mint()`, as `share()` does.
  - It must keep the slot count. A path that puts one slot too many deadlocks a release in `send` on a full channel.
  - It stops when the pool drops. No `select` exists, so a stop channel it polls with `recvTimeout` (the health
    check's period) is the shape: `Empty` (timed out) means do a round, `Closed` means stop.
- **S5's unit tests** go through `ScriptConnector` (`tests/unit/src/pool_test.kama`), which traces every connection's
  messages into the test's log. The pool's live restart cases go in the restart leg (`restart_test.kama`,
  `PGTEST_RESTART=1`).
- **The gate, per step:**
  - `tools/test.sh`, which runs the unit suite in debug and release;
  - `tools/test-integration.sh`, on 14–19 in debug, release and TLS, then the restart leg;
  - **`tools/mutate.sh tools/mutations/<step>.json --version 18`**. This runs each mutation in a copy of the tree and
    exits 1 unless every one makes its targeted case fail. S0b's 26 are in `s0b.json`, S1's 35 in `s1.json`, S2's 47
    in `s2.json` and S3's 27 in `s3.json`. Write a file per step, and re-run older files when their code changes. A
    `BAD-PATTERN` means the source moved on, so update the mutation. PANICKED is a run that died before any case
    failed; an entry may expect it, and may set `"env"` (the restart mutations set `PGTEST_RESTART=1`) and `"timeout"`.
    A run that times out is judged by what it printed first, since a pool mutant can fail its case and then deadlock
    (S3's P5).
  - A mutation whose code another line already guarantees is equivalent: rewrite the code or drop the mutation, and do
    not keep one that cannot fail. S3 dropped a check of `isClosed()` that the final check made redundant.
  - Run the integration mutations after the matrix, not beside it: both use the same servers.
  - A generator's output is committed: re-run it, and `git diff` must be empty (`tools/gen-reset-vectors.sh` for S1,
    `tools/gen-libpq-tables.sh` for S2a).
  - Never edit a script while it runs: `sh` reads it as it goes.
- **The compiler.** Build with the v0.9.673 release, as CI does, until the port above. The dev tree (`../cstar/out`) is
  past the release, and `~/.kama/bin/kama` is an old 0.9.440.
  - To get one: `kama-macos-universal-vX.tar.gz` from the `cosmic-canopy/kama` GitHub release, checked against its
    `.sha256` and unpacked anywhere (it holds `kama-macos-universal-vX/bin/kama`). A session's scratchpad does not
    outlive it, so download it again each session.
  - Run with `KAMA=<that>/bin/kama tools/test.sh`, or `curl -fsSL https://kama-lang.org/install.sh | KAMA_VERSION=vX sh`.
  - **The editor's diagnostics come from that old 0.9.440 language server.** It rejects a view's `~dtor` and cannot
    resolve this package's imports, so ignore it and trust `kama check`.
- **kama-tls.** `../kama-tls` is readable. The package needs `@kama/tls` ≥ 0.1.3 (its `TlsError` is `Sendable`), and
  the locks pin 0.1.4. kama-tls is busy with its own roadmap, so ask the maintainer before you need something there.
- **The servers.** `kama-pg-14` to `kama-pg-19` and their standbys run under podman (`tools/pg.sh`). The superuser's
  reset test leaves one object behind, by design: `kp_reset_seq`, a sequence in `kp_test`, made with `if not exists`.
  The restart leg leaves each primary running, and `test-integration.sh` runs `pg.sh up` after it.
- **CI has not run the restart leg yet.** It has run here under podman on macOS only. CI's integration job (docker on
  Linux) runs it from the first push of S2.
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
