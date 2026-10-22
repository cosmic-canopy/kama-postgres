# Changelog

All notable changes to this package are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions follow
[SemVer](https://semver.org/). In 0.x, a minor bump may break.

## [Unreleased]

### Added
- `Transaction`, the transaction a borrow window scopes, which `transaction()` now mints. Its methods are `conn()`,
  `began()`, `commit()`, `rollback()` and `setOptions(options:)`, which runs SET TRANSACTION.
- `TransactionOptions.modes()`: the transaction modes, as BEGIN and SET TRANSACTION take them.
- `Connection.ping()`: an empty query, which the server answers in a failed transaction block too.
- `Connection.resetSession()`: Npgsql 10.0.3's session reset, read from its source.
  - It rolls back an open block.
  - It sends `DISCARD ALL` when nothing is prepared. Otherwise it sends DISCARD ALL's parts except deallocating
    statements, so the statement cache and `prepare`d statements stay usable.
  - Each part is gated on the server's version as Npgsql gates it.
  - It takes one round trip, and is sent at once rather than in front of the next command, as Npgsql sends it, so a
    failure is reported to the caller. A failed reset closes the connection.
  - Notifications already received are dropped.
- A row or a column reads into std's `JsonValue`, now that a program can import std's JSON beside this package.
- **libpq's checks on a message header**, made on the header alone, before the body is waited for or room is made
  for it:
  - in a session, a length under 4, or over 30000 for a type that is never that long, is "lost synchronization with
    server: got message type "%c", length %d", and the session ends (fe-protocol3.c). The long types are libpq's
    `VALID_LONG_MESSAGE_TYPE`; during COPY OUT a ParameterStatus may be long too, as libpq's COPY reader takes it.
    PostgreSQL 18 reports `search_path`, so a `SET search_path` over 30000 bytes now ends the session here as it does
    in libpq;
  - before authentication, only an authentication request, NegotiateProtocolVersion or an error is accepted, checked
    on its first byte, and the first two must be 8–2000 bytes ("received invalid authentication request", "received
    invalid protocol negotiation message"). An ErrorResponse outside 8–30000 bytes is a pre-3.0 server's error text,
    read to its NUL as libpq reads it, and one that does not parse is "received invalid error message";
  - the type byte in libpq's messages prints as C's `%c` prints it (a NUL ends the message there).

  The long types, the limits and the messages are read from libpq's source by `tools/gen-libpq-tables.sh`
  (`src/protocol/framing.kama`), and the unit tests check every type and length in each place against libpq's outcome.
- **Bounds on what a server can make a connection hold** (`Limits`, set with `Config.setLimits`), each an `Optional`
  that `None` turns off:
  - `readBuffer`, the bytes taken in while a write waits (default 1 GiB): past it the connection closes;
  - `parameters`, the distinct ParameterStatus names (default 1,000): past it the connection closes;
  - `notifications`, the queue (default 10,000): past it the oldest is dropped, counted by
    `Connection.droppedNotifications()`, and logged as a warning at the first drop since the queue was last read;
  - `resultBytes`, the row bytes one call keeps (off by default; pgjdbc's `maxResultBuffer`): `query`, `simpleQuery`
    (its statements together), `getResult`, and `runBatch` (its results together). Past it the result is read to its
    end and dropped, the call fails, and the session and its transaction go on.

  Reaching a bound is the new `PgError::Limit`. `takeNotifications` no longer takes quadratic time.
- **`PgError::Lost`: a session's connection failing, in libpq's words** (pqsecure_raw_read and pqsecure_raw_write): a
  server that hung up (the end of the stream, EPIPE, ECONNRESET) is "server closed the connection unexpectedly…"
  whatever the client was doing, any other failure is "could not receive data from server: …", "could not send data
  to server: …" or "select() failed: …" with the operating system's words, and the `IoError` is kept as the cause.
  Before, a plain socket's failure printed the operating system's words alone ("Broken pipe"). After a failed write,
  what the read finds is reported first, as libpq reads on after one.
- **Server restarts are tested.** `tools/pg.sh stop|start|restart` (a fast shutdown; the data is kept), and a restart
  leg per server in `tools/test-integration.sh`: sessions open across a restart (plaintext, TLS, in a transaction
  block, with a cached statement, a command in flight, `ping` and `resetSession`), a connect while the server is down
  and while it starts, and the sessions after it. The words a session may report are libpq's; asked across a restart,
  the server's own psql printed the FATAL and then the lost connection.
- **`postgres::pool`: a connection pool shared by isolates.**
  - `Pool.make(config:, options:)` and `pool.acquire()`, which returns a `Lease`. The lease gives its connection back
    when it is dropped, and `lease.conn()` is the connection.
  - `pool.share()` and `Pool.join(share:)` use one pool from several isolates, with one bound between them.
  - At most `maxSize` connections, made only when acquired. `acquire()` waits up to `acquireTimeout`, then fails with
    the new `PgError::PoolTimeout`.
  - Release closes a connection that is closed, busy, in pipeline mode or past its lifetime. Otherwise it resets the
    session (`resetSession()`, which rolls back too), or, with `reset` off, rolls back an open block only. It also puts
    back the pool's query timeout and clears a notice handler.
  - `PoolOptions.defaults()` are pgxpool's (max(4, CPUs), a one-hour lifetime), with HikariCP's 90 seconds of lifetime
    jitter and a 30-second acquire timeout.
  - `Pool.makeWith(connector:, …)` takes a `Connector` that makes the connections.
  - **Maintenance:** the pool that made the connections runs an isolate that keeps them. It stops and is joined when
    that pool drops. Every `healthCheck` (1 minute, pgxpool's) it does four things:
    - it closes connections past their lifetime;
    - it closes the ones the pool has not needed: Npgsql's pruning, since the pool hands its idle connections out in
      turn, as Npgsql's channel does;
    - it pings, one at a time, each connection last known to be alive more than a second ago;
    - it connects until `minIdle` (0) are idle.
  - **Pruning:** each round records how many connections are idle. Once `idleTimeout` (30 minutes) has been recorded,
    the median of those counts is closed, never leaving fewer than `minIdle`.
  - **Acquire's ping:** acquire pings a connection last known to be alive more than a second ago, as pgxpool does. One
    that does not answer is closed, and the next idle one is taken; past the acquire's deadline, it connects instead.
  - **Ping bound:** every ping the pool sends is bounded by `pingTimeout` (5 seconds, HikariCP's validationTimeout).
  - **Connect bound:** the maintenance's connects are bounded by connect_timeout, or by acquireTimeout when there is
    none, so a pool's drop never waits on a connect that cannot end.
  - **Freed places:** an acquire that takes the place of a closed connection leases an idle connection waiting behind
    it, rather than connecting, so pruning and closes are not undone at once.
- **Seeded mutations of every scripted reply** (`tests/unit/src/garble_test.kama`). Eighteen conversations carry every
  backend message this client reads, in each state it can arrive in: startup with each authentication method and a
  protocol downgrade, the simple and extended protocols, the statement cache, a portal, COPY both ways, a pipeline, a
  notification, `ping` and `resetSession`, a transaction window, and TLS. Each reply in turn is changed ten ways (a
  flipped byte, four kinds of bad length, cut short, another type, dropped, sent twice, bytes inserted), with every
  choice drawn from a seed. The client must answer with a result or a `PgError` that says something, never panic, and
  end the session after a protocol error. `PGTEST_GARBLE_SEEDS` runs more seeds; 500 (a million cases) find nothing.
- **Examples** (`examples/`), each a program of its own that checks what it reads back and exits 1 when something is
  wrong:
  - `quickstart`;
  - `typed_rows`;
  - `transactions`;
  - `copy_csv`;
  - `notify_worker`, a LISTEN/NOTIFY worker;
  - `shared_pool`, a pool shared by isolates;
  - `batch`.

  Each takes a connection string as its argument, or reads libpq's `PG*` variables without one. `tools/test.sh` builds
  them. `tools/test-integration.sh` runs them against every server, in plaintext and over TLS with
  `sslmode=verify-full`. Every code block in the README is now code from one of them, which `tools/check-readme.sh`
  checks, so what a reader copies compiles.

### Changed
- **Needs kama ≥ 0.9.719.** It has, of what this package relies on:
  - `std::net`'s `Poller` over epoll and kqueue, which fills a caller's `Events` list (KR-230), first in 0.9.717. It
    replaced `std::net::Ready`, so no source builds on both sides of it. A socket's transport registers again only when
    what it waits for changes, since each registration is now a system call;
  - the refusal of code that cannot run (after a `while (true)` with no `break`, a `panic`, or a `match` whose every
    arm leaves), first in 0.9.707;
  - channels that return `Result` (`Undelivered<T>`, `RecvError`), which the pool is written against, first in 0.9.690;
  - a release build on macOS with `std::process` beside `std::concurrent` (KPG-41), first in 0.9.679: an application
    that uses the pool and starts a process;
  - a window opened through an enclosing window's alias freezes that alias, so `tx` cannot be used inside
    `borrow tx.conn().transaction() as inner` (KPG-40), first in 0.9.673;
  - std's JSON can be imported beside this package (KPG-39), first in 0.9.673.
- **Breaking: `transaction()` is a borrow window**, `borrow conn.transaction() as tx { … }`, which kama 0.9.658 made
  possible: a view's destructor runs when its window closes (KPG-35).
  - The window sends BEGIN, or SAVEPOINT inside a transaction block, so a window inside a window nests.
  - When the block is left by any path (its end, `return`, `break`, `continue`), the window rolls the transaction back
    (ROLLBACK, or ROLLBACK TO and RELEASE for a savepoint) unless it is over. It is over once the view committed or
    rolled it back, or once the server reported the block ended, so a COMMIT run through `tx.conn()` counts.
  - A window that cannot roll back (a COPY or pipeline mode left open, a ROLLBACK the server refuses) closes the
    connection, as pgx closes one whose rollback failed, and logs a warning under `postgres`.
  - BEGIN's options are `tx.setOptions(options:)`, since a mint takes no arguments, and BEGIN's outcome is
    `tx.began()`, since a mint cannot return a Result.
- **Needs `@kama/tls` ≥ 0.1.6**, the first that builds on kama 0.9.707 and later. (0.1.3 was the first whose
  `TlsError` is `Sendable`, which `PgError` needs.)
- **Breaking: `Transport.wait` returns `postgres::Ready`**, this package's own type, where it returned
  `std::net::Ready`, which kama 0.9.718 removed. It has the same shape (`Ready.of(readable:, writable:)`), so a
  `Transport` of your own changes its import and nothing else, and a later change to std's poller cannot break it
  again.
- **Breaking:** a session's I/O failure is `PgError::Lost(detail, cause)` instead of `PgError::Io`. `Io` stays for a
  failure to connect and for the caller's own streams (`copyFrom`'s Reader, `copyTo`'s Writer).
- **Breaking:** `postgres::protocol::frame` takes a `Framing` (`Startup`, `Session` or `CopyOut`), and `Frame` has an
  `OldError` case. A header libpq refuses is `ProtocolError::SyncLost(tag, length)`, its length signed as libpq reads it.
- The receive buffer grows only as a message's bytes arrive. A header that declares a 1 GiB message no longer costs
  1 GiB before any of it has come.
- A NoticeResponse before authentication is refused, as libpq refuses it. A server sends none there.
- A pre-3.0 error whose text is empty is "received invalid error message", where libpq reports an empty error: what it
  holds is a v3 header with a length under 8. Found by the seeded mutations of every scripted reply (below).
- **Breaking:** `PgError` has a new case, `PoolTimeout`, so an exhaustive `match` on it needs one more arm.
- `PgError` is `Sendable`, and so are `ServerError`, `ConnectError`, `ConnectAttempt`, `ProtocolError` and
  `ErrorFields`, so an error can cross isolates (a `Channel<PgError>`, or a `Sendable` type that holds one).

### Removed
- **Breaking:** `transaction(body:, options:)` and `TransactionBody`. The window replaces them, and kama has no
  overloading, so both cannot be called `transaction`. A body's statements move into the window's block, and what it
  kept in its fields becomes locals. `begin`, `commit`, `rollback` and the savepoint methods stay.

### Fixed
- **A TLS handshake no longer spins on a server that falls silent in it.** Waiting to read, the handshake took a
  transport that was only writable as ready, so a server that answered the SSLRequest with `S` and then said nothing
  kept the connection busy for ever, past `connect_timeout`. Only the side waited for counts now, and the deadline
  ends it as `timeout expired`. Found by @kama/redis, which runs the same loop over a scripted server that is always
  writable; a unit case here plays that server.
- **0.2.1's known issue is gone.** A program that imports std's JSON and uses this package compiles. The bug was kama's
  (KPG-39), and kama 0.9.673 fixes it.

## [0.2.1] — 2026-10-18

0.2.0 on the kama of today: 0.2.0 does not build on kama 0.9.667, whose serde contracts changed, and this does. Needs
**kama ≥ 0.9.667** and `@kama/tls` ^0.1.0 (0.1.1 builds unchanged on it). Verified on kama 0.9.667, debug and release,
on macOS arm64 and Linux, against PostgreSQL 14–18 and 19 beta, in plaintext and over TLS, each server with a hot
standby. The API is 0.2.0's.

### Changed
- **Needs kama ≥ 0.9.667.** kama's serde contracts changed (a deserialization error is now a `DeErrorKind` and a
  place), and the column reader and the parameter writer follow them:
  - a column can be asked what it holds (`peekKind`) and an integer, oid or float column for its exact text
    (`readNumberText`), so a type that reads whatever it finds (an untyped JSON value) can read a column;
  - `rowAs` still passes over a column that no field claims, as before, now through serde's `unknownField`.
- The 0.2.0 README's known issue (KPG-38, a release build failing when two files pass the same kind of parameter) is
  fixed in kama 0.9.543, so the note is gone.

### Known issue
- On kama 0.9.667, a program that imports std's JSON (`std::serialization::text::json`) and uses this package does not
  compile: the import makes `Optional<int64>` not `Sendable`, and `CopyChunk` holds one. A kama bug, filed as KPG-39;
  the README says what to do until a kama release fixes it.

## [0.2.0] — 2026-10-03

Phase 7, the full session. Needs **kama ≥ 0.9.523** and `@kama/tls` ^0.1.0. Verified on kama 0.9.523, debug and
release, on macOS arm64 and Linux, against PostgreSQL 14–18 and 19 beta, in plaintext and over TLS, each server with a
hot standby.

### Added
- **Cancel requests**, as libpq's PQcancelCreate and PQcancelBlocking make them:
  - `Connection.cancelToken()` gives a `CancelToken`, Sendable and copyable, so another isolate can cancel the
    session's running command with `cancel()` (or `cancelWith(dialer:)` for a session made with `connectWith`);
  - the request goes to the address the session used, with the session's sslmode, and so the same encryption and
    fallbacks (libpq 17's encrypted cancel); CancelRequest takes the place of the startup packet, and the server's close
    ends it, all within connect_timeout;
  - protocol 3.2's longer keys go whole;
  - libpq's messages: "no cancellation key received", "connection not open", "could not send cancel packet: …",
    "unexpected response from server", each with libpq's lead.
- **Query timeouts:** `Connection.setQueryTimeout(timeout:, grace:)`, as Npgsql's CommandTimeout and pgjdbc's
  setQueryTimeout behave (libpq has none):
  - when the limit passes, the command is cancelled through the session's route;
  - the server's 57014 is returned, and the session goes on;
  - if the server does not answer within `grace` (2 s by default), or the session has no route (`connectOver`), the
    connection is closed and the call returns `Timeout`.
- `PgError::Cancel`, for a cancel request that could not be made or sent.
- **Transactions:**
  - `begin(options:)`, `commit()` and `rollback()`. `TransactionOptions` takes an isolation level, READ ONLY or READ
    WRITE, and DEFERRABLE.
  - `savepoint()`, `releaseSavepoint(sp:)` and `rollbackToSavepoint(sp:)`, with names the connection gives (`sp_1`,
    `sp_2`, …).
  - `transaction(body:, options:)`, as psycopg's `with conn.transaction()` and pgx's BeginFunc run a body:
    - a `TransactionBody`'s `run(conn:)` runs between BEGIN and COMMIT, or ROLLBACK when it returns an error, which is
      then the call's;
    - inside an open transaction it nests as a savepoint.
  - `PgError::RolledBack` ("commit unexpectedly resulted in rollback", pgx's words) when COMMIT ends a failed
    transaction.
- **COPY**, as libpq runs it over the simple protocol:
  - in: `startCopyIn(sql)` (a `CopyInfo`: binary or text, each column's format), `putCopyData(bytes:)`, `endCopyIn()`
    (the rows copied) or `failCopyIn(reason:)` (CopyFail, abandoned);
  - out: `startCopyOut(sql)` and `getCopyData()`, which gives `CopyChunk::Data` per row, then `Done` with the count;
  - std::io: `copyFrom(sql:, source: Reader)` and `copyTo(sql:, sink: Writer)`, pgx's CopyFrom and CopyTo;
  - data goes out at 64 KiB, in messages of at most 1 MiB, and a server that has already failed the COPY stops it at
    the next put rather than after all the data;
  - libpq's "no COPY in progress"; any other call during a COPY is "another command is already in progress".
  `simpleQuery` and `query` still refuse COPY, and now name the calls to use.
- **A statement cache**, pgx's design. It is set with `Config.setStatementCache(mode:, capacity:)`, not the connection
  string, since libpq has no such keyword:
  - `CacheMode::Statements`, the default: each SQL text is prepared as a named statement (`sc0`, `sc1`, …) the first
    time and bound at once after, so a repeated query takes one round trip where it took two. At most `capacity`
    (512) are kept; the least recently used is closed ahead of the next Parse.
  - `CacheMode::Describe`: only descriptions are kept. The unnamed statement is parsed again with each run, with its
    types, and its portal is described in the same round trip, so the columns read are the server's current ones.
    This is for poolers without named statements.
  - `CacheMode::Off`: describe, then run, as before.
  - A cached plan the server will no longer run ("cached plan must not change result type", 0A000, after an ALTER
    TABLE) is dropped. Outside a transaction the query is run again once, as pgjdbc does; inside one the error is
    returned.
  - DISCARD ALL and DEALLOCATE ALL empty the cache.
- **Pipeline mode**, libpq's:
  - `enterPipelineMode()` and `exitPipelineMode()`; `sendQuery(q:)`, `sendPrepare(sql:)` and `sendClosePrepared(statement:)`;
    `pipelineSync()`, `sendPipelineSync()` and `sendFlushRequest()`; `pipelineStatus()`;
  - `getResult()` returns each command's `PipelineResult` in order: `Rows`, `Prepared`, `Closed`, `Failed`, `Aborted`
    or `Sync`;
  - after a failed command, the rest up to the next sync are `Aborted`, and the segment's implicit transaction is
    rolled back. An error at the sync itself (a deferred constraint) is a result of its own.
  - A query the cache knows, or a prepared statement's, goes typed, as outside a pipeline. Any other goes as libpq's
    PQsendQueryParams sends it: the unnamed statement; each parameter's natural type (int2/int4/int8 by width,
    float4/float8, bool, bytea, numeric past int64; none for a string or NULL); the values as text; the portal
    described; text columns.
  - Seven of libpq_pipeline's nine traces replay message for message (`tools/gen-pipeline-vectors.sh`). The other two
    name their own statements and portals, which this API does not do.
  - libpq's refusals, verbatim: "synchronous command execution functions are not allowed in pipeline mode", "cannot
    enter pipeline mode, connection not idle", "cannot exit pipeline mode with uncollected results", "cannot send
    pipeline when not in pipeline mode".
- **Batches**, pgx's SendBatch: `Batch.add(q:)`, then `Connection.runBatch(batch:)` gives a `BatchResult` per query
  (`Rows`, `Failed` or `Aborted`).
  - The SQL the statement cache does not know yet is described in one round trip and kept.
  - The whole batch then goes typed, with one sync, in a second round trip.
  - A failing query aborts the rest, and the batch, one implicit transaction, is rolled back.
  - A query that cannot be described fails the batch before anything runs.
- **`target_session_attrs`** (any, read-write, read-only, primary, standby, prefer-standby), libpq's
  CONNECTION_CHECK_TARGET:
  - after authentication, the server's reported `default_transaction_read_only` and `in_hot_standby` decide;
  - without them, the client asks, under connect_timeout: `SHOW transaction_read_only` or
    `SELECT pg_catalog.pg_is_in_recovery()`;
  - a server of the wrong kind gets Terminate, and the connect moves to the next host, with libpq's words ("session is
    read-only", "server is not in hot standby mode", …) as `PgError::Target`;
  - prefer-standby goes round the hosts a second time for any server.
- **`load_balance_hosts=random`**, as libpq does it: the hosts are tried in a random order, shuffled once per
  connect, and each host's addresses are shuffled as they resolve. A value other than `disable` or `random` is refused
  with libpq's "invalid load_balance_hosts value". Before, `random` was refused.
- **Waiting for notifications:** `Connection.waitForNotification(timeout:)` returns the oldest LISTEN/NOTIFY
  notification already received, else the next to arrive within the time (None when none does), taking in notices
  and parameter changes on the way. libpq leaves this loop to the application (PQsocket, PQconsumeInput, PQnotifies).

### Changed
- **Needs kama ≥ 0.9.523**, the release with the fixes for KPG-31 and KPG-32.
- The manifest gives the registry a `description`, a `repository` and `keywords`, new in kama 0.9.523.
- A client private key owned by root may be group-readable (0640), as libpq allows. Every other key must still be 0600
  or less. Before, with no way to read a file's owner, every key had to be 0600 or less.
- **Breaking:** `TransactionStatus` gains `Active`, reported while a command's result is still being read, as libpq's
  PQtransactionStatus reports PQTRANS_ACTIVE.
- **Breaking:** `PgError` gains `Cancel`, `RolledBack` and `Target`. A `match` that names every variant must add
  them.
- `Config` is `Copyable`: a copy is the whole configuration, as libpq's pqCopyPGconn copies a connection's options.
- Bind sends no format codes when every parameter is text, and Parse no types when none is given, as libpq does (each
  sent a 0 per parameter).
- **Queries are cached by default** (`CacheMode::Statements`): a server's error that names the statement names `sc…`
  rather than the unnamed statement. `CacheMode::Off` keeps the old exchange.

### Fixed
- While a request waits to be written, whatever the server sends is read into the buffer, as libpq's pqSendSome reads
  it. A server writing results for the commands it already has stops reading once its own output is full; a client
  that only wrote would then wait forever on a long request. Phase 7's pipelines and COPY rely on this.

## [0.1.0] — 2026-10-02

The first published version. Needs **kama ≥ 0.9.519** and `@kama/tls` ^0.1.0 (Mbed TLS 4.1.1), from the registry.
Verified on kama 0.9.520 (the latest release), debug and release, on macOS arm64 and Linux, against PostgreSQL
14–18 and 19 beta, in plaintext and over TLS. The "Changed" entries below record what changed while it was built,
before anything was published.

### Added
- **TLS**, as libpq built with SSL does it, through `@kama/tls`:
  - every `sslmode`, with libpq's order and fallbacks: `prefer` tries TLS and then plaintext, `allow` the other way
    round, on a new connection after a refusal, with libpq's lead printed for each; an SSLRequest answered 'N' goes
    on in plaintext on the same socket; a Unix socket is plaintext whatever sslmode says;
  - `sslnegotiation=direct` (PostgreSQL 17 and later), with ALPN "postgresql" required;
  - verification: a root file that exists verifies the chain under any mode, `verify-full` checks the server's name
    by libpq's rules (`postgres::verifyServerName`), `sslrootcert=system` with the environment's `SSL_CERT_FILE`,
    `sslcrl`/`sslcrldir` with OpenSSL's every-certificate rule;
  - client certificates: `sslcert`, `sslkey` (libpq's checks of the file, PEM or DER), `sslpassword` for encrypted keys,
    `sslcertmode` disable/allow/require;
  - `sslsni`, `ssl_min_protocol_version`/`ssl_max_protocol_version`, `sslkeylogfile` (NSS key-log lines);
  - SCRAM-SHA-256-PLUS, bound to the server certificate's tls-server-end-point hash whenever the server offers it and
    `channel_binding` is not `disable`;
  - `Connection.sslInUse()`, `sslAttribute(name:)` and `sslAttributeNames()`, as PQsslAttribute;
  - libpq's messages throughout; where libpq quotes OpenSSL, libpq's frame with Mbed TLS's reason. README lists
    what differs from a libpq built with OpenSSL.
- `Connection.connectWith(dialer:, config:)` and the `Dialer` contract: libpq's whole connection procedure (hosts,
  addresses, TLS fallbacks) over connections a caller opens. `connectOver` now honours sslmode for its transport.
- `PgError::Tls(detail, cause)`, and `Transport.explain(error:)`, through which a transport words its own failures.

### Changed
- **Needs kama ≥ 0.9.519**, which fixed every compiler gap this package filed (KPG-11 to KPG-30). Ported to its
  `IoError`, a kind and the OS's code. An I/O failure reads as libpq's does, with strerror's words ("Connection
  refused"): a connect, a socket option, a user lookup, peer credentials.
- The password file is checked on the file opened, as libpq checks it. One that is not a regular file
  (`/dev/null`, a FIFO, a directory) gets libpq's "is not a plain file" warning.
- With `HOME` unset or empty, the home directory is the account's, from its passwd entry, as libpq finds it.
- **The extended query protocol**, as libpq and pgx drive it: Parse and Describe, then Bind, Execute and Sync.
  - `Connection.query(q:)` gives `Rows`, and `execute(q:)` gives the count. A column of a type this client reads in
    binary comes in binary, every other one as text.
  - `Query`: SQL with `$n` and its parameters. `add(value:)` takes a `PgParam` and `addNull()` adds NULL.
    `PgParam` covers the primitives, `DynamicArray` (arrays, and bytea), `Optional` (None is NULL), `Uuid`,
    `Timestamp`, `Date` and this package's types. A `Serializable` type of your own joins with
    `implements PgParam`. Each value is sent as the type the server inferred: binary when it is that type's own
    kind, text otherwise, for the server's input function. Arrays go as array literals.
  - The `pg"… ${x} …"` tag makes each hole a parameter, never text in the SQL. Holes are typed: each is a
    `PgParam`, checked where the string is written, so an empty Optional is NULL and bytes are bytea.
  - `prepare(sql:)` gives a `Statement` ("s0", "s1", …) with its parameter types and columns, as
    PQdescribePrepared gives them. Run it with `Query.of(statement:)`, then `closeStatement`.
  - Chunked rows (libpq 17's mode): `startRows`, `nextRows(maxRows:)`, `discardRows`, `isStreaming`.
  - Portals in a transaction block: `openPortal`, `fetch(portal:, maxRows:)` (`suspended()` while rows remain),
    `closePortal`.
  - libpq's client-side refusals ("another command is already in progress", "number of parameters must be
    between 0 and 65535"). Every server error is returned once the server is ready again, and the session goes on.
    Any message out of place ends the session as a protocol error.
- **`Rows`**, one result type for both protocols, as libpq's PGresult is. It replaces `SimpleResult`, and the
  description of a column is `field(index:)`. It is `Sendable`.
- **Typed access**, through `Deserializable`: `column::<T>(rows:, row:, index:)`, `columnOpt::<T>` and
  `rowAs::<T>(rows:, row:)`. They work for primitives, `Uuid`, `Timestamp`, `Date`, bytea as
  `DynamicArray<uint8>`, PostgreSQL enums as kama enums, and `@generate(Deserializable)` structs by column name.
  - An integer reads into a type at least as wide as its column's, never narrower. Any column reads as a string:
    its PostgreSQL text. NULL reads only into an Optional.
  - `rowAs` refuses a row with no column for a field that is neither `Optional` nor `@field(default)`, and a row
    whose columns share a name.
  - `PgError::Value` names the column, its type, and what was asked.
- **Arrays of one dimension**, text and binary (`postgres::types::decodeArray`, `formatArray`, `ArrayValues`):
  `column::<DynamicArray<int32>>` and every other element type this client reads, `bytea[]` as
  `DynamicArray<DynamicArray<uint8>>`. A binary array read as a string is `array_out`'s text. An array of more
  dimensions, or one with a NULL element, is refused with the reason. `elementType(arrayOid:)` is generated with
  the other OIDs.
- `postgres::types`: `Numeric`, `LocalDateTime`, `TimeOfDay`, `TimeTz` and `Interval` are `Serializable` and
  `Deserializable` as PostgreSQL's text, so each reads from a column and travels through any serde backend.
  `LocalDateTime` is `Formattable`, and each has a `parse` constructor for that text.
- **SASLprep** is PostgreSQL's `pg_saslprep`, step for step, so a SCRAM password with non-ASCII characters
  (full-width letters, a no-break space, a ligature) logs in as it does with psql. `postgres::protocol` has
  `saslPrep` and `scramPassword`. The stringprep tables are generated from PostgreSQL's source
  (`tools/gen-saslprep.sh`). Tested against PostgreSQL's own `test_saslprep` outcomes and against verifiers a
  live server stored.
- A Unix-domain socket connects without blocking, so `connect_timeout` bounds the connect too. A full listen
  queue fails that host at once, as in libpq.
- `postgres::protocol`: `AuthError` messages are libpq's. `NegotiateProtocolVersion` carries `newestVersion`,
  the full version the server sends (it was misnamed `newestMinor`). `ProtocolError::Violation` covers a
  well-formed message out of place. `MessageWriter` is `Sendable`.
- **Licensed under MIT OR Apache-2.0**, at your option, like kama itself (`LICENSE-MIT`, `LICENSE-APACHE`).
  Copyright is Cosmic Canopy LLC and the kama contributors.

### Added
- `postgres::protocol`: every frontend message (Startup, SSLRequest, CancelRequest with 3.0 and 3.2 keys,
  Parse/Bind/Describe/Execute/Close/Sync, COPY, SASL); framing and decoding of every backend message, with
  bounds checks, UTF-8 validation, and a 1 GiB cap; MD5 and the md5 response; a SCRAM-SHA-256 client with
  tls-server-end-point channel binding (SCRAM-SHA-256-PLUS). Tested byte for byte against the protocol
  documentation, RFC 1321's MD5 suite and RFC 7677's exchange, including every truncation of every fixed-shape
  message and 4000 rounds of noise.
- `postgres::conninfo`: libpq-compatible connection strings (keyword=value and URI, multi-host, percent
  decoding, libpq's error wording). Tested against all 63 cases of libpq's URI regression suite.
- `postgres::sqlstate` (268 SQLSTATEs) and `postgres::types` OIDs (193 built-in types), generated from
  PostgreSQL's errcodes.txt and pg_type.dat.
- `postgres::types` codecs, text and binary: bool, int2/4/8, float4/8, oid, text/varchar/bpchar/name/json,
  jsonb, bytea (hex and escape), uuid, date, time, timetz, timestamp (LocalDateTime), timestamptz, interval
  (IntervalStyle postgres), and numeric (exact; NaN and ±Infinity). Tested against 97 values a live PostgreSQL
  18 produced in both formats.
- **Connections.**
  - `Config` and `Environment`: a connection string resolved as libpq resolves it. The service file
    (`pg_service.conf`) comes first, then the PG* environment, compiled defaults, the local user, and
    `.pgpass` per host. Every setting is checked with libpq's messages.
  - `require_auth` is libpq's, parse and enforcement.
  - Until TLS lands, this client behaves as libpq built without SSL: `sslmode` require and above are refused
    in libpq's words.
  - `target_session_attrs`, `load_balance_hosts=random` and replication are refused, not ignored.
- **`Connection`.**
  - Each host and each address is tried in turn, `connect_timeout` per address, with TCP keepalive and
    `tcp_user_timeout`.
  - A host that is a directory is a Unix-domain socket, and on Linux `@name` is the abstract namespace.
    `requirepeer` is checked against the socket's peer credentials, and libpq's path-length limit applies.
  - A failed connect carries libpq's hint line ("Is the server running…").
  - Authentication: trust, cleartext, md5, and SCRAM-SHA-256, including `scram_client_key` /
    `scram_server_key`. AuthenticationOk before the server proves its SCRAM signature is refused.
  - Protocol 3.0 or 3.2, with NegotiateProtocolVersion handled as libpq handles it.
  - `simpleQuery` gives `Rows`: text values checked as UTF-8 on arrival, `rowsAffected` as PQcmdTuples reads
    the tag. COPY is refused cleanly, and the session goes on.
  - Session state: parameters kept current, `serverVersion()`, the transaction status, a LISTEN/NOTIFY queue
    (`takeNotifications`).
  - Ending: `close()` and the destructor send Terminate. A FATAL error, EOF or protocol violation closes the
    connection, and later calls return `Closed`.
- **Errors and notices.**
  - `PgError` holds typed causes, and a failed connect keeps every attempt's own error. `sqlstate()` reaches
    through it.
  - `ServerError` has every ErrorResponse field, rendered as libpq's pqBuildErrorMessage3 renders them.
  - Notices go to a `NoticeHandler`, else to `std::log` under the tag `postgres`.
- **`Transport` and `Connection.connectOver`**: a session over a stream the caller opened (tokio-postgres's
  connect_raw). The built-in ones, `TcpTransport` and `UnixTransport`, are non-blocking sockets with a poller
  and deadlines.
- **`postgres::conninfo`**: `pgpassLookup` and `parseServiceFile`, ports of libpq's.
- **`tests/integration`, run by `tools/test-integration.sh` on PostgreSQL 14, 15, 16, 17, 18 and 19beta4,
  debug and release.** It covers:
  - every authentication method and refusal, and the 48 `require_auth` cases of PostgreSQL's 001_password.pl;
  - the service-file scenarios of 006_service.pl, `.pgpass`, and the environment;
  - queries, errors and their fields, notices, notifications and COPY refusal;
  - protocol negotiation, server-side termination, `connect_timeout`, and a connection moved between isolates;
  - Unix-domain sockets, through a relay the test runs, since a macOS host cannot reach a container's socket.
    It checks a query, `requirepeer` either way, a password-file entry for the socket directory, a missing
    socket, a path too long, and falling through to the next host.
- **Every built-in type this client reads round-trips on PostgreSQL 14–19**, debug and release
  (`tests/integration/src/types_test.kama`): 114 values from `tools/gen-codec-vectors.sh`, arrays included. For
  each, the binary bytes the server sends must be the vector's, it must read as the server's text from either
  protocol, and its kama value sent back must equal it, by the server's comparison.
- **Unit tests drive `Connection` against a scripted server** that sends a byte at a time: every auth path and
  its misbehaving variants, negotiation, hostile and truncated messages, and silence.
- `tools/gen-libpq-test-cases.sh`: the cases of PostgreSQL's TAP tests, extracted, and libpq's own verdicts
  on .pgpass files, service files and settings, asked of the test server's libpq.
- Generators, each pinned to its source by SHA256 and reproducible: `tools/gen-auth-vectors.sh`,
  `tools/gen-libpq-tables.sh`, `tools/gen-pg-catalog.sh`, `tools/gen-codec-vectors.sh`.
- The package scaffold: manifest, agent files, hermetic unit-test program (`tools/test.sh`).
- The integration server: `tools/pg.sh` runs the official PostgreSQL image (14–18, 19 beta) under podman or
  docker with TLS on and one role per authentication method; `tools/gen-test-certs.sh` generates its
  throwaway PKI. `tools/pg.sh smoke` passes on 14.24, 15.19, 16.15, 17.11, 18.4 and 19beta4.
