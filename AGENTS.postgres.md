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

**The package needs kama ≥ 0.9.486**, declared as `"kama"` in every manifest here. That is the first
compiler with everything this package relies on:
- a non-fatal write to a closed socket;
- a `Sendable` `TcpStream`;
- `recvTimeout`;
- `std::digest` HMAC/PBKDF2;
- Unix sockets;
- TCP keepalive;
- `std::process::currentUser`.

## What is true here and nowhere else

- **Native protocol, no C.** This package speaks the PostgreSQL v3 wire protocol in kama over `std::net`.
  There is no libpq, no `csrc/` and no `csources`, and it should stay that way. TLS comes from the sibling
  package `@kama/tls` (`../kama-tls`), which vendors Mbed TLS. That is the only native code in the
  dependency tree.

- **Two test programs, and neither is typed from memory.**
  - `tests/unit` is hermetic. It needs no server and no network, and runs through `tools/test.sh`, debug
    and release.
  - `tests/integration` needs a live server: `tools/pg.sh up --version N`, then
    `tools/test-integration.sh` (arrives with the first integration suite, in phase 4).
  - Vectors come from upstream by script: RFCs for the crypto, libpq's own URI regression file for
    connection strings, and a live server's `*_send()` functions for binary codecs.

- **`tools/pg.sh` is the server.**
  - It runs the official `postgres:N` image (14–18, plus 19 beta) under podman or docker, and
    `tests/integration/server/` configures it.
  - There is one role per authentication method: `kp_trust`, `kp_password`, `kp_md5`, `kp_scram`,
    `kp_cert`, `kp_ssl_only` and `kp_nossl`. A test picks the method by picking the user.
  - `tools/pg.sh smoke` logs in once per method with the container's own psql. When an integration test
    fails, run it first: it separates "the server is misconfigured" from "the client is wrong".
  - The test PKI is generated into `out/test-certs` by `tools/gen-test-certs.sh` and is never tracked.
    `kama publish` refuses a tracked `*.key`, and so does the registry.

- **Typed column access is a free function: `column::<T>(row:, index:)`.** A method cannot take type
  parameters, and cstar has decided that stays so (KPG-8). It is bounded on `Deserializable<T>`, the
  contract primitives, `std::uuid::Uuid`, `std::time::{Timestamp, Date}` and `@generate` structs already
  share. That matters because a package cannot add a contract to a type it does not own (SPEC,
  retroactive conformance is gone). `rowAs::<T>` is the same mechanism over a whole row.

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
  - `out` is reserved.

- **Nothing from the server is trusted.**
  - Every length is bounded before it is used.
  - Every text field is validated as UTF-8.
  - A malformed message is `PgError::Protocol`, never a panic. The unit tests feed truncated and oversized
    messages to prove it.

- **Publishing** goes through `../kama-registry` (`./ops publish ../kama-postgres/kama.json`) and happens
  only when the user says so, because a version is permanent. `@kama/tls` is published first.
  `kama publish kama.json --dry-run` must list no certificates and none of the agent files.
