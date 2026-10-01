# Changelog

All notable changes to this package are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions follow
[SemVer](https://semver.org/). In 0.x, a minor bump may break.

## [Unreleased]

Needs **kama ≥ 0.9.506**.

### Changed
- **Needs kama ≥ 0.9.506**, which fixed every compiler gap phases 3 and 4 filed (KPG-11 to KPG-22). Ported to
  its `IoError`, a kind and the OS's code: an I/O failure's message now quotes the operating system's words.
- The password file is checked on the file opened, as libpq checks it. One that is not a regular file
  (`/dev/null`, a FIFO, a directory) gets libpq's "is not a plain file" warning.
- With `HOME` unset or empty, the home directory is the account's, from its passwd entry, as libpq finds it.
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
  - `simpleQuery` gives `SimpleResult`s: text values checked as UTF-8 on arrival, `rowsAffected` as
    PQcmdTuples reads the tag. COPY is refused cleanly, and the session goes on.
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
