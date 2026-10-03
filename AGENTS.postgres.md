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

**The package needs kama ≥ 0.9.523**, declared as `"kama"` in every manifest here, and pinned in CI. That is the first
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
- `std::unicode` normalization, for SASLprep;
- typed tag holes (`Template<C>`) and `type adapter`, for the `pg` tag and `PgParam`;
- serde's `MissingField` and `@field(default)`, which `rowAs` relies on;
- `IoError.osMessage()`, for libpq's strerror text;
- floats printed in their shortest form, as PostgreSQL prints them;
- a `break` in a `match` arm that leaves the loop (KPG-32);
- `Metadata.owner`, for libpq's rule that a root-owned key may be 0640 (KPG-31).

## What is true here and nowhere else

- **Native protocol, no C.** This package speaks the PostgreSQL v3 wire protocol in kama over `std::net`.
  There is no libpq, no `csrc/` and no `csources`, and it should stay that way. TLS comes from the sibling
  package `@kama/tls` (`../kama-tls`), which vendors Mbed TLS. That is the only native code in the dependency tree.
  What postgres needs from TLS that the package lacks is added THERE, with its own tests, not worked around here.
  - All three manifests (root, `tests/unit`, `tests/integration`) take it from the registry (`"version": "^0.1.0"`),
    pinned by their `kama.lock`, so CI and a consumer build the published bytes.
  - To develop against an unpublished change in `../kama-tls`, give each manifest a `kama.local.json` (gitignored,
    never published) with `"overrides": { "@kama/tls": { "path": "<relative path to kama-tls>" } }`, then
    `kama pkg install`. postgres can only publish once that change is in a published `@kama/tls`.

- **Two test programs, and neither is typed from memory.**
  - `tests/unit` is hermetic. It needs no server and no network, and runs through `tools/test.sh`, debug
    and release.
    It includes a scripted fake server (`fake_server.kama`) that drives `Connection` through every startup and
    query path, hostile ones included: a reply a byte at a time, writes three bytes at a time, silence, hangups.
  - `tests/integration` needs a live server. `tools/test-integration.sh` starts each version itself (all of
    14–19 by default, `--version N` for one) and runs the suite debug and release. `types_test.kama` reads every
    codec vector on each version: its binary bytes, its text both ways, and its kama value sent back.
  - Vectors come from upstream by script:
    - RFCs for the crypto;
    - libpq's own URI regression file for connection strings;
    - a live server's `*_send()` functions for binary codecs (`tools/gen-codec-vectors.sh`, which writes the same
      file for both test programs);
    - for configuration and authentication, libpq itself (`tools/gen-libpq-test-cases.sh`): the cases of
      PostgreSQL's `001_password.pl` and `006_service.pl`, and the container's libpq asked live about
      `.pgpass` files, service files and settings.
    - for SASLprep, PostgreSQL's `test_saslprep` module and the SCRAM verifiers a live server stores
      (`tools/gen-saslprep.sh`).
    - for TLS (`tools/gen-ssl-vectors.sh`, no server needed): `001_ssltests.pl`'s host-name cases with upstream's
      certificates embedded, and every case of `005_negotiate_encryption.pl`, run as written against stubs; and a TLS
      table in `tools/gen-libpq-test-cases.sh`, each case asked of the container's libpq with the same files.

    A message this client prints is libpq's message, compared exactly. The one exception is where libpq quotes
    OpenSSL ("SSL error: %s", "could not load private key file \"%s\": %s"): there the frame is libpq's and the words are
    @kama/tls's, and the tests compare the frame (`sameAsLibpq` in tests/integration/src/tls_libpq_test.kama).
  - The unit tests' FakeServer runs Mbed TLS as the server when made with `secure`, and plays the server
    `005_negotiate_encryption.pl` configures (TLS on or off, injection points, its pg_hba lines) in policy mode,
    behind a `Dialer` that opens one per connection and reports each server's events.
  - `tools/test-integration.sh` runs the whole integration suite a third time per version, over TLS
    (`PGTEST_SSLMODE=require`). A test whose point is plaintext uses `plainConninfoFor`.

- **`tools/pg.sh` is the server.**
  - It runs the official `postgres:N` image (14–18, plus 19 beta) under podman or docker, and
    `tests/integration/server/` configures it.
  - There is one role per authentication method: `kp_trust`, `kp_password`, `kp_md5`, `kp_scram`,
    `kp_cert`, `kp_ssl_only` and `kp_nossl`. A test picks the method by picking the user.
  - `kp_saslprep` has a password that SASLprep changes, so it logs in only if this client prepares it as the
    server did.
  - `kp_md5_scram` has `md5` in pg_hba but a SCRAM-stored password, so the server runs SCRAM. This is
    upstream's md5 section of `001_password.pl`.
  - The database `kp_notice` raises a NOTICE on every login (a login event trigger, 17 and later), for testing
    startup notices.
  - `tools/pg.sh smoke` logs in once per method with the container's own psql. When an integration test
    fails, run it first: it separates "the server is misconfigured" from "the client is wrong".
  - The test PKI is generated into `out/test-certs` by `tools/gen-test-certs.sh` and is never tracked.
    `kama publish` refuses a tracked `*.key`, and so does the registry.

- **Typed column access is a free function: `column::<T>(rows:, row:, index:)`**, addressed as libpq's
  `PQgetvalue(res, row, col)` is, with `columnOpt::<T>` for a column that can be NULL and `rowAs::<T>(rows:,
  row:)` for a whole row into a `@generate(Deserializable)` type.
  - A method cannot take type parameters, and cstar has decided that stays so (KPG-8).
  - They are bounded on `Deserializable<T>`, the contract primitives, `std::uuid::Uuid`,
    `std::time::{Timestamp, Date}` and `@generate` structs already share. That matters because a package
    cannot add a contract to a type it does not own (SPEC: retroactive conformance is gone).
  - `src/decode.kama` decodes a column by its type, then serves it to `T.deserialize` through a `Deserializer`.
    The rules are in that file's header: an integer reads into a type at least as wide as its column's, never
    narrower; every column reads as a string, its PostgreSQL text; NULL reads only into an Optional.
  - `Rows` holds no `Shared`, so it stays `Sendable`. A row does not carry the column descriptions, which is
    why the functions take the result and a row index rather than a row.
  - The non-generic `valueReader`/`rowReader` do the work and hold the `friend` grants, so each instance of the
    generic functions stays small.
  - `rowAs` follows kama's serde: a field with no column is an error unless it is `Optional` (None) or
    `@field(default)` (its declared value). The derive decides that, not the reader.

- **The extended protocol describes first** (Parse and Describe, then Bind, Execute and Sync). One reader
  (`Connection.readRows`) reads every result and checks each message's place. A server error is returned once
  the server is ready, and FATAL or a message out of place ends the session. While a result is open
  (`busy`), every other call is refused with libpq's "another command is already in progress".
- **Parameters are `PgParam`s** (`src/query.kama`), a contract this package declares, with `type adapter`s for
  the primitives, `DynamicArray`, `Optional` (None is NULL), std's `Uuid`, `Timestamp` and `Date`, and its own
  types. Each writes itself through a `Serializer`. `Query.add(value:)` and the `pg` tag's holes
  (`Template<PgParam>`) both take one. A value goes binary when it is its type's own kind, and as text for the
  server's input function otherwise.

- **A connection is libpq's, step for step.**
  - `Config` resolves settings in libpq's order, and every setting is either honoured or refused with a clear
    error. Nothing is silently ignored.
  - This client is libpq built with SSL (Mbed TLS) and without GSSAPI, and says so in libpq's words.
  - `Connection.connect` walks PQconnectPoll: each host, each address, and at each address the encryption sslmode
    allows in its order (`postgres::secure::EncryptionPlan`). What a failure leads to is libpq's: 'N' goes on in
    plaintext on the same socket; a TLS failure or a refusal before authentication tries the next method on a new
    connection, printing libpq's lead again; 57P03 moves to the next host; connect_timeout to the next address;
    anything else ends the connect. A Unix socket is always plaintext.
  - `postgres::secure` (internal) holds TLS: `negotiate.kama` (the plan, the SSLRequest, direct negotiation, the
    post-handshake checks), `setup.kama` (initialize_SSL, step for step, a `TlsConfig` per attempt) and
    `transport.kama` (`TlsTransport`, TLS over ANY `Transport`). `postgres::verifyServerName` is libpq's host-name
    check, with glibc's inet_aton and inet_pton ported for "is this host an address".
  - `Connection.connectWith(dialer:, config:)` takes a `Dialer` and runs the whole procedure over connections it
    opens; `connectOver` treats its one transport as host 0 and makes one attempt.
  - Ports come from the pinned PostgreSQL source, not from memory. The source files are fetched by the
    generators, pinned by SHA256.
- **Notices go to std::log** under the tag `postgres` (WARNING as warn, NOTICE/INFO as info, DEBUG/LOG as
  debug), unless the connection has a `NoticeHandler`. Notices raised during startup always go to the log.
- **I/O is a `Transport`:** non-blocking `read`/`write` and `wait(interest:, timeoutMs:)`, plus `explain(error:)`,
  which words a failure as libpq does for that layer (a plain socket answers None).
  - `TcpTransport` is a non-blocking `TcpStream` plus a `std::net::Poller`. The internal module
    `postgres::wire` frames messages over any transport, with deadlines.
  - `UnixTransport` is the same for a socket host (a directory, or `@name` on Linux). Its connect is
    non-blocking too, bounded by connect_timeout.
  - `TlsTransport` wraps any `Owned<Transport>` (through `TransportStream`, a `ReliableStream` adapter). It never
    leaves ciphertext queued while the connection waits to read: `write` flushes first, `wait` flushes while it
    waits, and a buffered record is readable at once. The SSLRequest's answer is read on the transport before
    `Wire` exists; bytes after an 'N' reach `Wire.resume`.
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
  - A parameter cannot have the name of a function in scope (no shadowing): `column::<T>`'s column is `index:`.
    Nor can a match binding have the name of a local (`case Err(error: e)` beside a `Wire e`).
  - A `ConstView` local must be rooted: pass the view as a by-value parameter to a helper instead.
  - A row a loop drops must still be moved: `else { RowValues dropped = give r; }`.
  - `float` is reserved, as every C keyword is; so is `out`.
  - A resource that implements `Copyable<This>` must say its bare hand-off: `Copyable<This>(bare: give)`.
  - `DynamicArray.remove` returns `T` and `pop` returns `Optional<T>`.
  - A static function is called with `::` (`Connection::visit(…)`); `.` on a type calls a constructor.
  - A function that must build a resource through a private constructor gets a `friend` grant, or is a `static` of
    the type: a free function in the same file cannot call it.
  - An `IoError` is a value: branch on `e.kind()`, and make one with `IoError.of(kind: IoErrorKind::…)`.

- **Nothing from the server is trusted.**
  - Every length is bounded before it is used.
  - Every text field is validated as UTF-8.
  - A malformed message is `PgError::Protocol`, never a panic. The unit tests feed truncated and oversized
    messages to prove it.

- **Publishing** goes through `../kama-registry` (`./ops publish ../kama-postgres/kama.json`) and happens
  only when the user says so, because a version is permanent. `@kama/tls` is published first.
  `kama publish kama.json --dry-run` must list no certificates and none of the agent files.
