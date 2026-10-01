# @kama/postgres — what is true in THIS repo

The two generated files carry the general rules: `AGENTS.md` covers the language, and `AGENTS.package.md`
covers what a publishable library needs. `kama agents install` writes both, so they are **not**
hand-edited; a re-install rewrites them. This file is the project-specific third, and it is the one to
edit.

**Read [docs/ROADMAP.md](docs/ROADMAP.md) first.** It gives the order of work. Read
[KAMA_GAPS.md](KAMA_GAPS.md) for the compiler gaps this package has hit.

- **A gap goes in KAMA_GAPS.md the moment it is hit**, reduced to a repro and run on the named compiler.
  The cstar project reads that file and fixes from it, usually within a session. So do not build a
  workaround you would not want to delete. If a workaround is unavoidable, name it in the entry.

**The package needs kama ≥ 0.9.506**, declared as `"kama"` in every manifest here. That is the first
compiler with everything this package relies on:
- a non-fatal write to a closed socket;
- a `Sendable` `TcpStream`;
- `recvTimeout`;
- `std::digest` HMAC/PBKDF2;
- Unix sockets, connected without blocking;
- TCP keepalive;
- `std::process::currentUser` and the account's home directory;
- `IoError` as a kind and the OS's code (`match (e.kind())`), with `Interrupted`;
- `FileKind`, and `File.metadata()` on an open file;
- `std::unicode` normalization, for SASLprep.

## What is true here and nowhere else

- **Native protocol, no C.** This package speaks the PostgreSQL v3 wire protocol in kama over `std::net`.
  There is no libpq, no `csrc/` and no `csources`, and it should stay that way. TLS comes from the sibling
  package `@kama/tls` (`../kama-tls`), which vendors Mbed TLS. That is the only native code in the
  dependency tree.

- **Two test programs, and neither is typed from memory.**
  - `tests/unit` is hermetic. It needs no server and no network, and runs through `tools/test.sh`, debug
    and release.
    It includes a scripted fake server (`fake_server.kama`) that drives `Connection` through every startup and
    query path, hostile ones included: a reply a byte at a time, writes three bytes at a time, silence, hangups.
  - `tests/integration` needs a live server. `tools/test-integration.sh` starts each version itself (all of
    14–19 by default, `--version N` for one) and runs the suite debug and release.
  - Vectors come from upstream by script:
    - RFCs for the crypto;
    - libpq's own URI regression file for connection strings;
    - a live server's `*_send()` functions for binary codecs;
    - for configuration and authentication, libpq itself (`tools/gen-libpq-test-cases.sh`): the cases of
      PostgreSQL's `001_password.pl` and `006_service.pl`, and the container's libpq asked live about
      `.pgpass` files, service files and settings.

    A message this client prints is libpq's message, compared exactly.

- **`tools/pg.sh` is the server.**
  - It runs the official `postgres:N` image (14–18, plus 19 beta) under podman or docker, and
    `tests/integration/server/` configures it.
  - There is one role per authentication method: `kp_trust`, `kp_password`, `kp_md5`, `kp_scram`,
    `kp_cert`, `kp_ssl_only` and `kp_nossl`. A test picks the method by picking the user.
  - `kp_md5_scram` has `md5` in pg_hba but a SCRAM-stored password, so the server runs SCRAM. This is
    upstream's md5 section of `001_password.pl`.
  - The database `kp_notice` raises a NOTICE on every login (a login event trigger, 17 and later), for testing
    startup notices.
  - `tools/pg.sh smoke` logs in once per method with the container's own psql. When an integration test
    fails, run it first: it separates "the server is misconfigured" from "the client is wrong".
  - The test PKI is generated into `out/test-certs` by `tools/gen-test-certs.sh` and is never tracked.
    `kama publish` refuses a tracked `*.key`, and so does the registry.

- **Typed column access is a free function: `column::<T>(row:, index:)`.** A method cannot take type
  parameters, and cstar has decided that stays so (KPG-8). It is bounded on `Deserializable<T>`, the
  contract primitives, `std::uuid::Uuid`, `std::time::{Timestamp, Date}` and `@generate` structs already
  share. That matters because a package cannot add a contract to a type it does not own (SPEC,
  retroactive conformance is gone). `rowAs::<T>` is the same mechanism over a whole row.

- **A connection is libpq's, step for step.**
  - `Config` resolves settings in libpq's order, and every setting is either honoured or refused with a clear
    error. Nothing is silently ignored.
  - Until phase 6 this client is "libpq built without SSL", and says so in libpq's words.
  - Ports come from the pinned PostgreSQL source, not from memory. The source files are fetched by the
    generators, pinned by SHA256.
- **Notices go to std::log** under the tag `postgres` (WARNING as warn, NOTICE/INFO as info, DEBUG/LOG as
  debug), unless the connection has a `NoticeHandler`. Notices raised during startup always go to the log.
- **I/O is a `Transport`:** non-blocking `read`/`write` and `wait(interest:, timeoutMs:)`.
  - `TcpTransport` is a non-blocking `TcpStream` plus a `std::net::Poller`. The internal module
    `postgres::wire` frames messages over any transport, with deadlines.
  - `UnixTransport` is the same for a socket host (a directory, or `@name` on Linux). Its connect is
    non-blocking too, bounded by connect_timeout.
  - Phase 6 adds a TLS transport, after the SSLRequest exchange on the concrete `TcpStream`. `Connection` does
    not change.
  - The integration tests reach the server's socket through a relay of their own (`socket_test.kama`).
    `PGTEST_SOCKDIR` is a short directory under /tmp, made by the runner, since a socket path is at most 103
    bytes on macOS.
- **Connections move between isolates.** A `Connection` is `Sendable`, which means every field must be:
  - Handlers are `Owned<Contract>`, where the contract `implements Sendable`.
  - Never put a `Shared` in a `Connection`; it is a non-atomic count.

- **The pool shares connections through a channel.**
  - Idle connections sit in a `Channel<Connection>`. The pool claims `sender()` and `receiver()` before
    the `Channel` drops, because dropping it closes any side nobody claimed.
  - A lease keeps its connection in a zero-or-one `DynamicArray`, since a destructor cannot `give` a
    field but can `pop()`. It returns the connection through a `Shared` return path.
  - `acquire(timeout:)` is `recvTimeout`.

- **Language habits this code base needs, each learned from a compiler error:**
  - A `resource` field is always private.
  - Match a resource payload through a named local and `give`: `Optional<T> x = f(); match (give x) { … }`.
  - `new` goes only in a local initializer: `Owned<H> h = new Impl.make(); this.h = give h;`.
  - A `Shared<T>` is made with `new T.make(...)`.
  - `spawn` takes exactly one bundle argument.
  - Interpolation holes take identifiers only, so bind a call to a local first.
  - Reserved words bite as names: `out`, `base`, `final`, `addr`, `ref`, `in`, `const`. The full list is in
    the cstar SPEC under "kama's keywords".
  - A value-producing `match` may only initialize a local or be returned. It cannot be an operand of `&&`, so
    bind it first. A block arm that yields a value ends with `:= expr;`.
  - A value declared outside a loop cannot be given inside it, even right before a `return`: set a flag, leave
    the loop, then give.
  - A field cannot be moved out (`give this.x`). Build values in place, or drain a `DynamicArray` with `pop()`.
  - A `ref` parameter cannot name an `Owned<T>`. Pass the `Owned` by value and hand it back.
  - `DynamicArray.remove` returns `T` and `pop` returns `Optional<T>`.
  - An `IoError` is a value: branch on `e.kind()`, and make one with `IoError.of(kind: IoErrorKind::…)`.

- **Nothing from the server is trusted.**
  - Every length is bounded before it is used.
  - Every text field is validated as UTF-8.
  - A malformed message is `PgError::Protocol`, never a panic. The unit tests feed truncated and oversized
    messages to prove it.

- **Publishing** goes through `../kama-registry` (`./ops publish ../kama-postgres/kama.json`) and happens
  only when the user says so, because a version is permanent. `@kama/tls` is published first.
  `kama publish kama.json --dry-run` must list no certificates and none of the agent files.
