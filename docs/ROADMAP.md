# Roadmap

Where this is, 2026-10-22: phases 0–8 are done, and phase 9 (Windows) is under way on a Windows 11 machine; its plan
is below. 0.3.0 carries phase 8, on kama 0.9.719, and is published. 0.2.0 carried phase 7, and 0.2.1 is 0.2.0 on kama 0.9.667. 0.1.0
was phases 0–6, with `@kama/tls` 0.1.0. The client connects and queries on every supported server
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
- **Phase 8.**
  - A pool shared by isolates, with a maintenance isolate: minIdle, Npgsql's pruning, pings and lifetimes.
  - Transactions scoped by a borrow window, which nests as savepoints.
  - Hardening against a hostile server: libpq's header checks, bounds on what a server can make a connection hold, and
    seeded garbling of every reply.
  - Sessions and the pool across a server restart, tested live.
  - Seven examples, from which every code block in the README is taken.

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
macOS, a release build with `std::process` beside `std::concurrent` failed in clang), found in S2c, is fixed in 0.9.679,
and the package needed 0.9.690. kama 0.9.719's new `Poller` (KR-230) took a port of its own, and the package now
needs 0.9.719. Phase 8 is done, and its plan and record are below. Phase 9 opened two gaps: KPG-42 (std has no
application-data folder, where libpq keeps its files on Windows) and KPG-43 (std's parse of `NaN` takes the C library's
bits, which differ on Windows).

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
| 8 | Scoped transactions; pool (cross-isolate, with maintenance); hardening (server restart, bounded memory, hostile input); examples; docs. Ends at 0.3.0 | **done** (0.3.0): S0 (0.2.1), S0b, S1, the port to kama 0.9.673, S2, S3, the port to 0.9.690, S4, S5, S6, the port to 0.9.719 and S7 |
| 9 | Windows: libpq's WIN32 branches, a native server on Windows, Windows CI legs. Ends at 0.4.0 | **under way**: S0, S1, S2 and S3 done; S4 written, untested until pushed |
| 10 | Kerberos: GSSAPI (Linux, macOS), SSPI (Windows) and `gssencmode` | planned, design first |
| — | Publish `@kama/tls` 0.1.0, then `@kama/postgres` 0.1.0, its `@kama/tls` dependency switched from the path to that version | **done** (2026-10-02) |

## Phase 9, planned

Decided with the maintainer on 2026-10-22, on the Windows 11 machine. `@kama/tls` 0.1.7, its phase 7, is the
Windows release this phase waited for. Each step commits on main once it is green: `tools/test.sh` on Windows, debug
and release; from S2 on, the Windows integration leg; and Linux and macOS unchanged (CI, after a push on the
maintainer's word). Each step's mutations go in `tools/mutations/p9-sN.json`.

**Decisions:**
- **The server on Windows is EDB's binaries zip**, unpacked by `tools/pg.sh` into `out/`, the same locally and on CI's
  `windows-latest`.
  - No podman: on Windows it runs Linux containers in a WSL2 VM, which this machine lacks and GitHub's Windows runners
    cannot run.
  - A server in a VM could not be reached by a Unix-domain socket.
  - The zip's own `psql.exe` is a Windows libpq to ask the WIN32 cases of.
- **One version on Windows: 18, moving to 19 at GA.** 19 is at rc1, and EDB has no Windows zip of it. The 14–19
  matrix stays on Linux.
- **Every file is LF in every checkout** (`.gitattributes`: `* text=auto eol=lf`).
  - Git for Windows defaults to `core.autocrlf=true`, and so do GitHub's Windows runners.
  - With CRLF, the container's init script breaks, and `copy_csv`'s byte comparison fails.
- **SSPI and GSSAPI are refused in libpq's words in phase 9**, and phase 10 adds Kerberos on every platform.
  - On Windows, libpq always has SSPI (Windows' Kerberos/NTLM sign-on).
  - Npgsql, pgjdbc and asyncpg support it, and the package is to be complete rather than wait for a request.
- **libpq's application-data folder is a kama gap** (KPG-42).
  - libpq asks Windows for it: `SHGetFolderPath(CSIDL_APPDATA)`.
  - `homeFrom` reads `APPDATA` until std can ask, as Go's `os.UserConfigDir` does.
- **Phase 9 ends at 0.4.0.**

**What is known** (read on 2026-10-22, from the pinned REL_18 sources and kama 0.9.719):
- **libpq's WIN32 branches:**
  - The home is the app-data folder plus `/postgresql`, holding `pgpass.conf`, `.pg_service.conf`, `postgresql.crt`,
    `postgresql.key`, `root.crt` and `root.crl`.
  - Nothing checks the password file's or the key's permissions.
  - `DEFAULT_PGSOCKET_DIR` is `""`, so the default host is TCP `localhost`, and `is_absolute_path` takes `\`, `X:\`,
    `X:/` and UNC paths.
  - `requirepeer` fails the connect ("requirepeer parameter is not supported on this platform").
  - Keepalives set only idle and interval (`SIO_KEEPALIVE_VALS`, defaulting to 7200 s and 1 s); `keepalives_count`
    is not even parsed, and `tcp_user_timeout` is parsed and not applied.
  - Socket errors are `winsock_strerror`'s table with ` (0x%08X/%d)` appended (`win32.c`, SHA256 `c68436eb…fdeb7`).
  - The user name comes from `GetUserName`.
- **kama on Windows:**
  - std has TCP with its keepalive options, AF_UNIX path sockets (no abstract names) and the `Poller` (AFD over an
    I/O completion port). The `Poller` had not run on Windows before this phase; the unit tests open no socket, so the
    integration leg is its first live test.
  - CreateProcess cannot run a `.sh`.
  - The release with zig bundled (`kama-windows-x64-bundled-vX.tar.gz`) prefers its own zig to any clang on the PATH.

**Steps:**
- **S0, done: the baseline** (2026-10-22).
  - **Line endings.** `.gitattributes` makes every file LF, and the tree was checked out again.
  - **@kama/tls.** It is `^0.1.7` in the three manifests, and all ten locks pin 0.1.7.
  - **The first Windows run.** `kama check` refused one line: `tls_test.kama` read `UserId.raw()`, which Windows has
    not. With that gated, 7 of the unit cases failed, debug and release alike. Nothing else failed: no panic, nothing
    from the `Poller`, which the unit tests do not reach.
    - Five expected Unix's `HOME`. They became `homeTests` and `setHome`/`tlsHome`, with a Windows twin each that
      checks `APPDATA`'s `postgresql`, `pgpass.conf`, and the TLS files with no `.postgresql/`.
    - Two read `'NaN'` as text with other bits than binary: KPG-43. std's parse takes UCRT's NaN
      (`7fffffffffffffff`). `floatText` now gives the canonical NaN (`7ff8000000000000`) wherever it runs.
    - The key-permission cases follow 001_ssltests.pl, which skips them on Windows: a key at 0644 or 0640 connects.
  - **The gate is green on Windows**, on both compilers: `../kama` at v0.9.719 with msys2's clang, and the release with
    zig bundled. That covers the unit program debug and release, the seven examples, and the README check.
  - **Tooling for Git Bash.** `mutate.sh` copies the tree with tar when there is no rsync. Its Python reads and writes
    UTF-8 with no newline translation, and gives an example `APPDATA` and `SYSTEMROOT`. It and `check-readme.sh` take
    `$PYTHON`, else the first of `python3` and `python` that runs.
  - **Mutations:** `tools/mutations/p9-s0.json` has 8, all caught: the NaN, the five parts of the Windows home and its
    files, and the Windows key check.
- **S1, done: libpq's WIN32 branches** (2026-10-22). Each is a `@compileFor(OS_WINDOWS)` twin, read from the pinned
  source.
  - **Configuration** (`src/config.kama`, `src/conninfo/pgpass.kama`):
    - `defaultSocketDir()` is `""`, so the default host is `localhost` over TCP, and no socket directory is
      `localhost` to the password file.
    - `isSocketPath` is `is_unixsock_path` over a per-platform `is_absolute_path`: `/` on Unix, which fixes Unix
      taking `C:/x`; `/`, `\`, UNC and `X:\`/`X:/` on Windows.
    - `passfileUsable` checks nothing.
    - `keepalives_count` is not read.
    - The user name's failure reads "user name lookup failure: error code N".
  - **Connecting** (`src/session/route.kama`):
    - `requirepeer` over a socket is refused ("requirepeer parameter is not supported on this platform").
    - Keepalives are set as `pqSetKeepalivesWin32` sets them (7200 s and 1 s by default, failing in
      `WSAIoctl(SIO_KEEPALIVE_VALS)`'s words), and `tcp_user_timeout` sets nothing.
    - `absent()` takes only the not-found kind: `win32error.c` maps nothing to ENOTDIR.
    - A cancel request's connection that fails a read while it waits for the server's close has closed
      (`Wire.awaitEnd`). `PQcancelPoll`'s errno check is `#ifndef WIN32`, since Windows reports a clean close as
      `ECONNRESET` at times. The first live run found it: every cancel failed on Windows, so a query timeout closed its
      session.
  - **The OS's words** (`src/wire/wire.kama`, `src/wire/win32.kama`):
    - A Winsock code (10000–11999) is `winsock_strerror`'s: its table, then ` (0x%08X/%d)`.
    - Any other code goes through PostgreSQL's `_dosmaperr` to an errno, in the UCRT's `strerror` words.
    - `tools/gen-win32-errors.sh` generates the three tables. The sources are the pinned `win32.c` and `win32error.c`,
      and mingw-w64 v13.0.0's `winerror.h` and `errno.h` for the constants. The UCRT texts come from a probe, which
      only runs on Windows.
  - **libpq's order for a client key:** one that is not a regular file is refused from its `stat`, before it is
    opened. On Windows a directory cannot be opened as a file, so the open failed first with "Permission denied".
  - **EDB 18.6's `psql` agreed, asked live** against the native server:
    - a password file others can read is used;
    - `NUL`, `/dev/null`, a directory and a missing file give no password and no warning;
    - a refused connect reads `Connection refused (0x0000274D/10061)`;
    - `keepalives_count=abc` is accepted;
    - the default host is reached over TCP.
  - **Tests.**
    - `config_test`'s `platformTests`: the socket-path forms, `keepalives_count`, and a real password file at 0600,
      at 0644 and as a directory, with or without libpq's warning by platform.
    - A Windows twin of the pgpass default-socket case.
    - `lost_test`'s `osWordTests`: a real EADDRINUSE from a second listener on a held port, injected into a session.
    - `tls_test`: a key that is a directory, and the keylog warning's ENOENT words, one warning per secret.
    - The `lost` cases now say `sslmode=disable`. On Windows the default host is TCP, and an SSLRequest went first.
  - **Mutations:** `tools/mutations/p9-s1.json` has 19, all caught. `p9-s1-unix.json` holds the Unix half (the
    `C:/x` fix and `keepalives_count`), for the Mac, since a mutation compiled out here cannot fail.
  - **Left to S3's live suite:** the keepalive, `requirepeer` and cancel twins, the user name's failure, and
    `absent()`. The unit tests open no socket, and cannot make the account lookup fail.
- **S2, done: a native PostgreSQL 18 on Windows** (`tools/pg-native.sh`, which `tools/pg.sh` sources when `uname` is
  MINGW or MSYS; `PGTEST_NATIVE` overrides the choice).
  - **The binaries:** EDB's `postgresql-18.6-1-windows-x64-binaries.zip`, cached in `out/pg-dist/`.
    - EDB publishes no checksums, so its SHA256 (`fbe23da2…252f8c`) is the one taken when it was first pinned.
    - Only `bin`, `lib` and `share` are unpacked: about 150 MB of the 900. Git for Windows' unzip stops `*` at a `/`,
      so the patterns are `**`.
  - **The server:** initdb (UTF8, `en-US`), then `00-setup.sh`, which now takes `KP_CERTS` and `KP_DIR`, so the
    container and the native mode share it. It listens on loopback only, since binding every interface raises Windows
    Firewall's prompt. The roles come from `10-roles.sql`, and the standby from `pg_basebackup -R` on 544N.
  - **The commands:** `up`, `down`, `stop`, `start`, `restart`, `env`, `psql`, `logs` and `smoke`, with the
    container's ports and environment file. A first `up` takes 17 seconds.
  - **`pg_ctl` runs with every handle detached.** On Windows the server it starts (through `cmd.exe`) inherits them:
    the first `pg.sh up | tail` never ended, since the server held the pipe.
  - **`smoke` uses the zip's own psql**, and all 20 logins pass. `kp_saslprep`'s password goes through a password file,
    since libpq reads `PGPASSWORD` in the ANSI code page on Windows, which cannot hold it.
  - **`tools/gen-libpq-win-cases.sh`** asks that psql 17 cases into `tests/integration/src/libpq_win_cases.kama`, with
    each path and port as a placeholder. Run twice, its output is identical. The cases are:
    - the password file's checks;
    - socket paths: a missing directory (`WSAENETDOWN`), an empty one (`WSAECONNREFUSED`), and `@name` (`WSAEINVAL`);
    - `requirepeer` over TCP;
    - keepalives and `tcp_user_timeout`;
    - the key's checks;
    - the default host;
    - a refused connect.
- **S3, done: the integration suite on Windows**, against 18.
  - **The runner.** `tools/test-integration.sh` defaults to 18 on Windows, and gives the examples `APPDATA`. The restart
    tests run `sh` with `tools/pg.sh` as its argument (`pgshCommand`), since CreateProcess cannot start a script.
  - **Windows twins**, each from the live psql:
    - the refused-connect words (`refusedWords()`);
    - `auth_test`'s password-file cases: no checks, and the null device is `NUL`;
    - `socket_test`: the drive letter's colon escaped in the password file, `requirepeer` not supported, and a missing
      directory's `WSAENETDOWN`;
    - `tls_libpq_test`'s shared key, which connects;
    - `types_test`'s NaN: the Windows server sends the UCRT's bits.
  - **`windows_test.kama`** replays the 17 generated cases through this client. 15 are compared exactly. Two check
    libpq's lead and hint, their words awaiting KPG-44 (std reports `ERROR_FILE_NOT_FOUND` where Winsock answered
    `WSAECONNREFUSED`) and KPG-45 (std has no abstract address on Windows). A configuration error is compared without
    the connection lead, as the unit settings cases are.
  - **The first live run found three things:**
    - Every cancel failed: Windows reported the server's clean close as a reset. The port went into S1.
    - A pipeline's query timeout then closed its session, and the test's `drained` loop spun on the closed connection
      for six hours. It now stops once the connection is closed.
    - The server's NaN differs, which corrected KPG-43's premise.
  - **The whole suite is green on Windows:** debug, release, TLS, the restart leg, and the seven examples in plaintext
    and over `verify-full`. Unix-domain sockets ran live through the relay, and kama's `Poller` (AFD over IOCP) carried
    every connection.
  - **Mutations:** `tools/mutations/p9-s3.json` has 9 integration mutations: the cancel, `requirepeer`, `absent()`,
    default host, password file, `keepalives_count`, socket path, Winsock words and key-order twins.
  - **Two twins have no mutation:** the keepalive values and `tcp_user_timeout`. A server cannot see a client socket's
    options, and both connect either way.
- **S4: CI** (`.github/workflows/ci.yml`), pushed on 2026-10-23 with the maintainer's word.
  - A `windows-latest` unit leg, with kama's release with zig bundled, by URL and SHA256, as `@kama/tls` installs it.
  - An `integration (windows, PostgreSQL 18)` job, with EDB's zip under `actions/cache`, keyed by its SHA256.
  - Every Windows step runs in Git Bash, and `KAMA_VERSION` is set once for the workflow.
  - **The first run** (`aae0d4b`) passed all eight Linux and macOS jobs, the Unix half of S1–S3 included. Both Windows
    jobs failed within 20 seconds, and a job's log needs an admin token.
  - **`tools/ci-annotate.sh`:** each test step now tees its output, and a failure turns its last 60 lines into an
    annotation, which the public check-runs API serves.
  - **The second run** (`bed1a36`) showed the cause: kama's `pkg install` cannot unpack a registry package on Windows
    (KPG-46, HIGH). This machine never met it, since its store already held `@kama/tls`.
  - **`tools/seed-kama-store.sh`** is the workaround, a step in both Windows jobs. It puts each locked package into
    kama's store, checked against the lock's integrity hash, byte-identical to kama's own entry.
- **S5: docs and 0.4.0.** The README's platforms, Windows file locations and known differences; the CHANGELOG;
  AGENTS.postgres.md's Windows gate; this record.

**How the gate runs here** (Git Bash):
- `PATH=/c/msys64/ucrt64/bin:$PATH KAMA=../kama/out/UCRT64-x86_64/kama.exe tools/test.sh`. msys2's UCRT64 gives clang
  and python3. Git Bash's own `python3` is the Microsoft Store's stub, which the scripts pass over.
- The same, with `KAMA` set to the v0.9.719 bundled-zig release, is CI's compiler.

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
- **The port to kama 0.9.690, done (2026-10-20).** v0.9.679 was the first release with KPG-41's fix, and v0.9.690
  came out an hour later with KR-214. The floor is `>=0.9.690`, since code written against KR-214's channels does not
  build on 0.9.679 (the maintainer approved raising it to the release with KPG-41's fix).
  - KPG-41's repro ran as filed on 0.9.679 and, with `fn uint8 main()`, on 0.9.690; the entry moved to FIXED. Its
    workaround is gone: the restart group builds in release, and the restart leg runs the release build.
  - KR-214: `send` is `_ = tx.send(item: …);` (the discard drops an undelivered item), and `tryRecv`/`recvTimeout`
    are `Result<T, RecvError>`. Nothing else was a discarded `Result`: this code base binds every one.
  - `main` is `fn uint8 main()` in both test programs and the README.
- **S4, done: maintenance** (`src/pool/pool.kama`, planned with the maintainer on 2026-10-20).
  - **Options:**
    - `minIdle`: 0, pgxpool's; at most maxSize.
    - `idleTimeout`: 30 minutes; at least healthCheck, as Npgsql requires; None never prunes.
    - `healthCheck`: 1 minute, pgxpool's.
    - `pingTimeout`: 5 seconds, HikariCP's validationTimeout.
  - **The isolate.** One per pool that made the channels (`PoolCore.keepUp`), stopped and joined when that pool drops:
    `Maintenance { Isolate worker; Sender<Stop> stop; }`, with the stop sender dropped first. It connects to minIdle at
    once. Then, every healthCheck, a round:
    - takes every slot with nothing sent, and counts the idle ones;
    - closes those past their lifetime and those pruned, after putting the kept ones back, then the Empties;
    - pings, one at a time, each connection last known to be alive (`Slot::Idle`'s `checked`) more than 1 s ago,
      taking slots only while the sweep counted one that may need it;
    - connects until minIdle are idle.

    It never waits on a channel, holds at most one connection while it sends anything, and checks for the stop before
    each ping, close and connect. Its connects are bounded by connect_timeout, or by acquireTimeout when there is none
    (`Config.boundConnects`), so a drop never waits forever.
  - **Pruning is Npgsql's, not pgxpool's** (decided with the maintainer): `slots` is FIFO, as Npgsql's idle channel is,
    so connections are leased in turn. pgxpool's idle time per connection (made for LIFO reuse) would never shrink a
    pool while any traffic goes on, and almost every acquire would ping.
    - Each round records the idle count. Once ceil(idleTimeout / healthCheck) rounds are recorded, the sorted counts'
      element at ceil(window / 2) − 1 is closed, from the longest idle, and the window starts again.
    - Each connection retired counts toward it, as in Npgsql's loop, and minIdle is the floor.
    - Ported from Npgsql v10.0.3 (commit `d3768398c178`), `src/Npgsql/PoolingDataSource.cs` (`c4b07159…6049`):
      `PruneIdleConnectors`, `DivideRoundingUp`, the constructor's sample size, median index and refusal.
  - **Acquire** pings a connection last known to be alive more than 1 s ago, within pingTimeout (pgxpool's rule).
    - One that does not answer is closed, and the next idle connection is taken, as pgxpool and HikariCP retry.
    - Past the acquire's deadline, it connects on the freed place instead.
    - An acquire that takes an `Empty` leases an idle connection waiting behind it, if there is one, rather than
      connecting. Without that, the FIFO channel undid a prune at once (found while writing the trickle test).
  - **Tests.**
    - Unit (`tests/unit/src/pool_test.kama`, "maintenance"): minIdle at the start and after a loss; pruning (its window,
      its floor, a burst pruned under a trickle, and the median, with counts 0, 0, 2 and 0, 2, 2); lifetime; the
      maintenance's pings, and a dropped connection it replaces; acquire's ping, a failed one passed over, and its bound
      and deadline; a freed place behind an idle connection; the drop's promptness, mid-wait, mid-ping and mid-connect,
      with and without connect_timeout; the bound after rounds of churn; refusals and defaults.
    - The FakeServer gained `pinged` (it answers a ping whenever it comes) and `Stall` (every later wait takes its
      timeout). `ScriptConnector`'s forks share its scripts, so the maintenance connects over them. A stray reset of the
      tracer and garbling after a `Late` reply (mechanical edits in 1f30846 and cfebc8d) is gone.
    - Integration (`tests/integration/src/pool_test.kama`), plaintext and TLS: minIdle sessions before any acquire,
      pruning down to minIdle, and a backend ended with `pg_terminate_backend` replaced by acquire's ping and by the
      maintenance.
    - Mutations: `tools/mutations/s4.json` (40 unit, 4 integration). S3's P11 follows the lifetime check into `usable`.
    - Four lines have no mutation:
      - the stop check before a retired connection's close, and the one before a fill's connect, since no scripted
        server is slow to close, or slow to connect without failing;
      - the ping pass's gate on its count of stale connections, and the round putting its kept connections back
        before its Empties. Each only narrows a race that no deterministic test can hit (a mutation of the order
        survived).

      Both came from a flaky trickle test: while the maintenance holds an idle connection for nothing, an acquire can
      find only an Empty and connect needlessly.
- **S5, done: pool tests** (planned with the maintainer on 2026-10-21). No change to the source was needed.
  - **Live, the pool across a server restart** (`tests/integration/src/pool_restart_test.kama`). It runs in the restart
    leg after `restart_test.kama`'s group, with a restart and a stop/start of its own. Its pools connect over plain TCP,
    so a refused connect is libpq's refusal, word for word:
    - idle connections the restart ended are passed over by acquire's ping, and the bound holds;
    - the maintenance replaces the minIdle connections the restart ended;
    - a lease held across it fails in libpq's words, and its place comes back on release, used or not (the unused one's
      reset fails on the dead connection);
    - while the server is down, each acquire, one more than maxSize, fails with the connect's error and never with
      PoolTimeout; once the server is back, the bound holds, and a pool made while it was down connects to minIdle.
  - **Unit, what S3's and S4's cases left.** These were found by comparing `pool.kama` with S3's and S4's mutations, then
    by a sweep of every `put`, `take` and loop bound not yet mutated:
    - a waiter in another isolate woken by a closed connection's place, which it connects on through its joined pool's
      connector;
    - a pool dropped while every connection is leased: the maintenance, which finds no capacity, waits on no channel.
      A lease that outlives its pool closes its connection when it is dropped;
    - lifetimes spread by lifetimeJitter (every older case set the jitter to zero);
    - the places an acquire passes over to reach an idle connection (`idleWaiting`), the idle connections the
      maintenance passes over to reach a free place (`claim`), and the free places the ping pass meets while an acquire
      takes a connection it counted (a strict server whose Stall step the ping takes, so the ping waits out
      pingTimeout);
    - a round pings every stale connection, and replaces one that fails in the same round;
    - the median of counts 1, 1, 3 is 1: pruning closes the median's count, not every idle connection;
    - the maintenance's connect bound is acquireTimeout rounded up to a whole second, and an acquireTimeout of 0 still
      bounds it by a second (a connect_timeout of 0 would be none, and the pool's drop would hang);
    - a transaction window on a lease, as the README shows it;
    - a negative lifetimeJitter, queryGrace and queryTimeout refused;
    - the bound under churn: four isolates acquire, close and release through one pool of 3 while connects are refused,
      lifetimes of 30 to 60 ms end, pruning runs and minIdle is connected again; after it, 3 leases can be held and not
      a fourth.
  - **Mutations:** `tools/mutations/s5.json`, 18 unit and 5 integration (the restart leg's, with `PGTEST_RESTART=1`).
    All are caught. The unit ones ran in a copy of the tree whose `main` runs only the pool group (see the gate below).
  - **One line has no mutation:** the retire loop's `Empty` arm, which cannot be reached, since the sweep's list holds only
    idle connections. S4's four lines stand as S4 left them.
- **S6, done: examples** (planned with the maintainer on 2026-10-21). No change to the source was needed.
  - **Seven programs**, each `examples/<name>/`, its own executable project, as in @kama/sodium and @kama/redis:
    - `quickstart`;
    - `typed_rows`;
    - `transactions`;
    - `copy_csv`, which reads the `items.csv` beside it;
    - `notify_worker`;
    - `shared_pool`;
    - `batch`.

    Each checks what it reads back, prints what was expected, and exits 1. Their tables are temporary: on 15 and later
    `kp_trust` cannot create a table in `public`, and a pooled connection's reset drops temporary tables, so
    `shared_pool` uses none.
  - **The server comes from libpq's environment.** The connection string is the first argument, or `""`, so the `PG*`
    variables, service file and `.pgpass` apply, as for psql with no argument.
  - **Each example's `kama.lock`** pins the newest `@kama/tls` the range admits (0.1.6), as a consumer's would. That
    is redis's practice. The package's own locks stay at 0.1.4.
  - **The README is code from the examples.** `tools/check-readme.sh` (hermetic, run by `tools/test.sh`) requires
    every ```` ```kama ```` block to be a run of consecutive lines of some `examples/*/src/*.kama`, after each side's
    common indentation is stripped. A failure names the README line, the nearest run and the first line that differs.
    This is stricter than redis's check, which builds only the README's complete programs. The README's
    `setStatementCache` line became prose, and its pool section three excerpts of `shared_pool`.
  - **Scripts:**
    - `tools/test.sh` builds every example, debug and release, then runs the README check.
    - `tools/test-integration.sh` builds them once, and per version, after the restart leg, runs each from its own
      directory, debug in plaintext and release over TLS (`sslmode=verify-full`, with the test CA). Each run gets
      `env -i` with the `PG*` variables and a scratch `HOME`, so nothing of the developer's environment is read.
    - `tools/mutate.sh` gained two suites:
      - `"example"`, which builds and runs one example as the integration runner does, in plaintext;
      - `"readme"`, which runs `tools/check-readme.sh`.

      In both, a mutation is caught when the run exits other than 0 and printed the `expect` text.
  - **Mutations:** `tools/mutations/s6.json`, 8 for the examples and 3 for the README check. All are caught.
- **The port to kama 0.9.719, done (2026-10-22).** kama tagged v0.9.707 and v0.9.719 after S6. The registry checks a
  publish with cstar's newest build, so a 0.3.0 left on 0.9.690 could not publish: `kama check` found 74 errors on
  0.9.719, in this package and in `@kama/tls` 0.1.4. @kama/redis met the same wall (its KRD-16).
  - **The floor is `>=0.9.719`**, the first tag with KR-230. No source builds on both sides of KR-230. `@kama/tls` is
    `^0.1.6`, the first that builds on 0.9.707. All three locks pin 0.1.6, as the examples' already did.
  - **KR-230 removed `std::net::Ready`**, which `Transport.wait` returned. It now returns `postgres::Ready`, the
    package's own type, with the same shape, so a consumer's `Transport` changes only its import. This was decided
    with the maintainer on 2026-10-22: @kama/redis's KRD-16 plans the same, and tokio kept its own `Ready` when mio 0.7
    removed mio's. cstar's ruling (ROADMAP_DETAIL §6) said nothing of downstream contracts.
  - **`TcpTransport` and `UnixTransport` share a `Waiter`:** a `Poller`, a one-event `Events`, and the interest last
    registered. Each registration is now a system call (epoll_ctl, kevent), so it registers again only when the
    interest changes.
  - **0.9.707 refuses code that cannot run:** 19 statements in `src/` and 12 in the tests, each a `return` after a
    `while (true)`, a `panic`, or a `match` whose every arm leaves. `string.find` returns `Optional<isize>`, which only
    the tests use.
  - The relay in `socket_test.kama` waits on `Events`, by token.
  - **Mutations:** `tools/mutations/port719.json`, two integration mutations of the `Waiter`. W1 never registers the
    socket again; W2 swaps readable and writable. Both are caught: the first login times out. S2's ten `wire.kama`
    mutations ran again and are caught. Each of the 213 older entries' patterns still occurs once.
  - **Two lines have no mutation:**
    - The connect's timeout check: no live case connects to an address that never answers, and the unit tests never
      open a socket.
    - The `foreach` that ORs the events together: with one event per wait it matches a plain read of that event.
- **S7, done: docs and 0.3.0** (2026-10-22).
  - The README's links are absolute, because the registry renders a relative link as plain text and `docs/` is not
    shipped.
  - Its status note, install line and kama floor say 0.3.0, and "What it covers" gives `column::<T>`'s real signature.
  - The CHANGELOG's 0.3.0 entry opens with what upgrading from 0.2 takes. `kama.json` says 0.3.0.
  - AGENTS.postgres.md says how a release goes.
  - **The release:** main was pushed with the 0.3.0 commit. That push was CI's first run of S2 to S7. Every Linux job
    passed, the restart leg included, and `unit (macos-arm64)` failed.
    - The log needs a token, so a fresh clone was run as CI runs it, and it failed the trickle pruning case. It is S4's
      race: a sweep counts the idle connections by taking them. An acquire that lands between two of its takes finds
      only an Empty and connects, and the script had no connection to spare, so the connect was refused.
    - The same transient exists beside pgxpool's health check (`AcquireAllIdle`). std's channel has no length, so the
      sweep cannot count without taking. The production cost is one extra connect within maxSize, which the next prune
      undoes.
    - Measured on 100 runs of the case: 98 connect 0 times and 2 connect once. With no `idleWaiting`, every run
      connects 3 times.
    - So the case now allows one connect, and spare scripts let it succeed. `s7.json`'s T1, which removes
      `idleWaiting`, is caught. The pool group then passed 15 debug and 10 release runs.
    - `v0.3.0` is tagged only once CI is green, so a missing tag means CI failed: read its log first.

**Decisions:**
- **On release, roll back and reset the session.** Npgsql and asyncpg do; pgx and deadpool do not. It is the safer
  default and costs one round trip. A pool can turn it off.
- **The reset is sent as the connection is released, not in front of its next command** (decided 2026-10-18, in S1).
  Npgsql prepends it, which saves the round trip. But a reset that fails would then surface on the next user's command,
  after that command had been sent and possibly run. Sent at once, a failure is the releaser's, and the pool closes the
  connection. asyncpg, and pgbouncer's `server_reset_query`, also reset before the connection is used again.
- **A maintenance isolate.** pgxpool, HikariCP, Npgsql, sqlx and bb8 all have one.
- **Every ping the pool sends is bounded by `pingTimeout`** (5 s, HikariCP's validationTimeout; decided 2026-10-20, in
  S4). A ping to a half-open connection would otherwise wait for TCP's retransmissions, past acquireTimeout, and stall
  the maintenance and the pool's drop with it.
- **idleTimeout prunes as Npgsql does, by the median of sampled idle counts** (decided 2026-10-20, in S4). The pool's
  idle queue is a FIFO channel, as Npgsql's is, and pgxpool's idle time per connection would never shrink it while any
  traffic goes on.
- **Windows is phase 9.**
- **Phase 8 ends at 0.3.0, not 1.0.0.** kama is pre-1.0, Windows is not done, and the first users of the pool may ask
  for changes.

**What the next session needs to know** (written 2026-10-22, after 0.3.0):
- **Where it stands.**
  - Phase 8 is done, in 0.3.0, and no gap is open.
  - The registry publishes 0.3.0 on the maintainer's word (`../kama-registry`, `./ops publish`).
  - Pushing and tagging also wait for the maintainer.
- **Check with cstar's newest build before calling a release ready.** The registry checks a publish with it, not with
  CI's tag, so run `kama check kama.json` with `../cstar/out/Darwin-arm64/kama` too. This is how 0.3.0 found it needed
  a port: kama tagged 0.9.707 and 0.9.719 between S6 and S7, and KR-230 changed `std::net`'s `Poller`.
- **Next: phase 9, Windows**, planned on 2026-10-22 (see "Phase 9, planned"). What was known before it:
  - **libpq's WIN32 branches** in the pinned sources say what changes: the password and service files' places, the
    key file's permission check, `requirepeer`, and Unix-domain sockets. Read them there, not from memory.
  - **The poller needs no branch.** KR-230 put std's `Poller` on AFD over an I/O completion port on Windows (0.9.718),
    so the `Waiter` stays as it is.
  - **@kama/tls had to build and pass there first.** Its 0.1.7 (its phase 7) does, and imports the certificate store's
    roots for `trustSystem()`, which `sslrootcert=system` relies on.
  - **The target.** kama's `--target WINDOWS` is `<arch>-windows-gnu`, and the platform branches here are
    `@compileFor(OS_…)`.
- **Writing an example** (`examples/<name>/`):
  - The manifest is the other examples' (`"@kama/postgres": { "path": "../.." }` alone), and `kama pkg install` writes its
    `kama.lock`, which is committed.
  - It takes the connection string from its first argument, or `""`. It checks what it reads back and exits 1 with one
    line saying what was expected.
  - Its tables are temporary. A table a pooled connection needs across leases cannot be temporary, and `kp_trust`
    cannot create one in `public` on 15 and later.
  - A README block is copied from an example, never typed: change the example, then copy its lines. `tools/check-readme.sh`
    names the nearest run and the first line that differs.
  - A new example needs a mutation in `src/` that its own check catches (`"suite": "example"`).
- **Writing a pool case** (`tests/unit/src/pool_test.kama`):
  - **Choosing the connector.** `keptPool` (`ScriptConnector.pinging`) answers a ping whenever it comes, taking no step,
    so a `Stall` in its script is reached only by a message that is not a ping. A case whose ping must go unanswered
    uses the strict `poolOver`, and scripts the pings it expects (`pingPassKeepsPlaces`).
  - **A script ends with its last step.** A message past the end of the script is never answered, and with no query
    timeout the client waits for ever. A case that queries a lease it is not sure of sets the pool's `queryTimeout`.
  - **Timing.** The maintenance cases keep margins of 200 ms or more around the rounds they count on. A case that needs
    something under way (a ping that waits) waits for it in the log (`awaitLines`), rather than guessing which round
    starts it. The new pool cases passed five debug and five release runs of the pool group, then the whole gate. If a
    case flakes in CI, widen its margin rather than retrying it.
- **The gate, per step:**
  - `tools/test.sh`, which runs the unit suite in debug and release, builds the examples and checks the README;
  - `tools/test-integration.sh`, on 14–19 in debug, release and TLS, then the restart leg, then the examples;
  - **`tools/mutate.sh tools/mutations/<step>.json --version 18`**. This runs each mutation in a copy of the tree and
    exits 1 unless every one makes its targeted case fail. S0b's 26 are in `s0b.json`, S1's 35 in `s1.json`, S2's 47
    in `s2.json`, S3's 27 in `s3.json`, S4's 44 in `s4.json`, S5's 23 in `s5.json`, S6's 11 in `s6.json`, the port to 0.9.719's 2 in
    `port719.json` and S7's 1 in `s7.json`. All were run on 0.9.690, S3's again on S4's code, and the port's with S2's `wire.kama` ones on 0.9.719.
    Write a file per step, and re-run older files when their code changes. A `BAD-PATTERN` means the source moved on, so update the mutation. PANICKED is
    a run that died before any case failed; an entry may expect it, and may set `"env"` (the restart mutations set
    `PGTEST_RESTART=1`) and `"timeout"`. A run that times out is judged by what it printed first, since a pool mutant
    can fail its case and then deadlock (S3's P5).
  - A mutation whose code another line already guarantees is equivalent: rewrite the code or drop the mutation, and do
    not keep one that cannot fail. S3 dropped a check of `isClosed()` that the final check made redundant.
  - Run the integration mutations after the matrix, not beside it: both use the same servers.
  - To iterate on one group, build a scratch copy of the tree whose `tests/unit/src/main.kama` calls only that group.
    A pool mutation then takes about a minute rather than three, and `tools/mutate.sh` run from that copy mutates
    the copy.
  - A generator's output is committed: re-run it, and `git diff` must be empty (`tools/gen-reset-vectors.sh` for S1,
    `tools/gen-libpq-tables.sh` for S2a).
  - Never edit a script while it runs: `sh` reads it as it goes.
- **The compiler.** Build with the v0.9.719 release, as CI does. The dev tree (`../cstar/out`) may be past the release,
  and `~/.kama/bin/kama` is an old 0.9.440.
  - To get one: `kama-macos-universal-vX.tar.gz` from the `cosmic-canopy/kama` GitHub release, checked against its
    `.sha256` and unpacked anywhere (it holds `kama-macos-universal-vX/bin/kama`). A session's scratchpad does not
    outlive it, so download it again each session.
  - Run with `KAMA=<that>/bin/kama tools/test.sh`, or `curl -fsSL https://kama-lang.org/install.sh | KAMA_VERSION=vX sh`.
  - **The editor's diagnostics come from that old 0.9.440 language server.** It rejects a view's `~dtor` and cannot
    resolve this package's imports, so ignore it and trust `kama check`.
- **kama-tls.** `../kama-tls` is readable. The package needs `@kama/tls` ≥ 0.1.6, the first that builds on kama
  0.9.707 and later, and every lock pins 0.1.6. kama-tls is busy with its own roadmap, so ask the maintainer before you
  need something there.
- **The servers.** `kama-pg-14` to `kama-pg-19` and their standbys run under podman (`tools/pg.sh`). The superuser's
  reset test leaves one object behind, by design: `kp_reset_seq`, a sequence in `kp_test`, made with `if not exists`.
  The restart leg leaves each primary running, and `test-integration.sh` runs `pg.sh up` after it.
- **CI.** The push of 0.3.0 was CI's first run of the restart leg, on Linux under docker. Before that it had run only
  here, under podman on macOS.
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
