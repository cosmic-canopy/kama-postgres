# Changelog

All notable changes to this package are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions follow
[SemVer](https://semver.org/). In 0.x, a minor bump may break.

## [Unreleased]

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
- **Waiting for notifications:** `Connection.waitForNotification(timeout:)` returns the oldest LISTEN/NOTIFY
  notification already received, else the next to arrive within the time (None when none does), taking in notices
  and parameter changes on the way. libpq leaves this loop to the application (PQsocket, PQconsumeInput, PQnotifies).

### Changed
- **Needs kama ≥ 0.9.523**, the release with the fixes for KPG-31 and KPG-32.
- A client private key owned by root may be group-readable (0640), as libpq allows. Every other key must still be 0600
  or less. Before, with no way to read a file's owner, every key had to be 0600 or less.
- **Breaking:** `TransactionStatus` gains `Active`, reported while a command's result is still being read, as libpq's
  PQtransactionStatus reports PQTRANS_ACTIVE.
- `Config` is `Copyable`: a copy is the whole configuration, as libpq's pqCopyPGconn copies a connection's options.
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
