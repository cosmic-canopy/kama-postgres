# @kama/postgres

The PostgreSQL client for [kama](https://kama-lang.org). It speaks the PostgreSQL v3 wire protocol directly,
in kama, over `std::net`, the way pgx, tokio-postgres, pgjdbc and Npgsql do. There is no libpq and nothing to
install. TLS comes from [`@kama/tls`](https://github.com/cosmic-canopy/kama-tls).

```sh
kama pkg add kama.json @kama/postgres --version ^0.2.0     # from the official registry, registry.kama-lang.org
```

Needs **kama ≥ 0.9.673**, declared in the manifest, so an older compiler is refused by name. Tested, debug and
release, on macOS arm64 and Linux, against PostgreSQL 14–18 and 19 beta.

> **Status: early.** It connects, authenticates and runs queries, with typed parameters and typed rows, over TCP, a
> Unix-domain socket or TLS (every `sslmode`, client certificates, SCRAM-SHA-256-PLUS). The statement cache,
> transactions and savepoints, COPY, waiting for notifications, pipelining and batches, cancellation and query timeouts,
> `target_session_attrs` and `load_balance_hosts` came in 0.2.0. Not there yet: a pool. See [docs/ROADMAP.md](docs/ROADMAP.md). In 0.x, a minor version may break the API.

## Using it

```kama
import { core::println, std::collections::DynamicArray,
         postgres::Config, postgres::Connection, postgres::PgError, postgres::Rows, postgres::column,
         postgres::columnOpt };

fn int32 main() {
    // A libpq connection string; the service file, PG* variables and ~/.pgpass apply as they do for psql.
    Result<Config, PgError> parsed = Config.parse(text: "postgresql://app@db.internal/inventory?connect_timeout=5");
    Config config = match (give parsed) { case Ok(value: c): give c; case Err(error: e): { println(s: e.message()); return 1; } };
    Result<Connection, PgError> opened = Connection.connect(config: config);
    Connection conn = match (give opened) { case Ok(value: c): give c; case Err(error: e): { println(s: e.message()); return 1; } };

    Result<DynamicArray<Rows>, PgError> r = conn.simpleQuery(sql: "select name, qty from items order by name");
    DynamicArray<Rows> results = match (give r) { case Ok(value: v): give v; case Err(error: e): { println(s: e.message()); return 1; } };
    isize i = 0;
    while (i < results[0].rowCount()) {
        // Typed access, as PQgetvalue addresses a value: the result, the row, the column.
        Result<Optional<string>, PgError> name = columnOpt::<string>(rows: results[0], row: i, index: 0);
        Result<int32, PgError> qty = column::<int32>(rows: results[0], row: i, index: 1);
        match (give name) {
            case Ok(value: n): { match (give n) { case Some(value: s): { println(s: give s); } case None: { println(s: "(null)"); } }; }
            case Err(error: e): { println(s: e.message()); }
        };
        i = i + 1;
    }
    conn.close();
    return 0;
}
```

Parameters go through the extended protocol, with the `pg` tag or a `Query`. A hole is always a parameter, never
text in the SQL. Holes are typed: an empty `Optional` is NULL, and a `DynamicArray<uint8>` is bytea:

```kama
Optional<string> supplier = Optional::None;
Query q = pg"select name, qty from items where qty > ${least} and supplier is not distinct from ${supplier}";
Result<Rows, PgError> r = conn.query(q: q);
```

`rowAs::<T>` reads a row into a `@generate(Deserializable)` type by column name. A row or a column also reads into
std's `JsonValue`, when its shape is not known in advance. `prepare` gives a reusable
`Statement`. `startRows`/`nextRows` read a large result a chunk at a time, and `openPortal`/`fetch` read a
cursor inside a transaction.

A server error is `PgError::Server` with every field PostgreSQL sends. Compare `e.sqlstate()` with the
constants in `postgres::sqlstate`. Messages read as psql prints them. With no `NoticeHandler` set, notices go
to `std::log` under the tag `postgres`.

## TLS

TLS is libpq's, setting for setting: `sslmode` from `disable` to `verify-full` with libpq's fallbacks (`prefer` tries
TLS and then plaintext, `allow` the other way round, each on a new connection after a refusal),
`sslnegotiation=direct` (PostgreSQL 17 and later), `sslrootcert` (a file, or `system`), `sslcrl` and `sslcrldir`,
`sslcert`/`sslkey`/`sslpassword`, `sslcertmode`, `sslsni`, `ssl_min_protocol_version`/`ssl_max_protocol_version`,
`channel_binding` and `sslkeylogfile`. As in libpq, a root certificate file that exists means the server's chain is
verified under any `sslmode`, and `verify-full` checks the server's name by libpq's rules (subjectAltNames, then the
CN, one-label wildcards).

```kama
Result<Config, PgError> parsed = Config.parse(text: "host=db.internal dbname=inventory user=app sslmode=verify-full sslrootcert=/etc/pg/ca.crt");
// … connect as above; then:
bool encrypted = conn.sslInUse();
Optional<string> protocol = conn.sslAttribute(name: "protocol");   // "TLSv1.3"
```

`Connection.connectWith(dialer:, config:)` takes a `Dialer` (pgx's DialFunc) that opens each connection, through a
tunnel or a proxy, and still gets libpq's host, address and encryption fallbacks. `Connection.connectOver(transport:,
config:)` starts a session over one transport the caller opened, TLS included.

The TLS library is Mbed TLS, through [`@kama/tls`](https://github.com/cosmic-canopy/kama-tls), not OpenSSL. What
that changes:

- Where libpq quotes OpenSSL's own words, this client prints libpq's frame with its own: `SSL error: certificate
  verify failed: the certificate is not correctly signed by the trusted CA` where psql says `SSL error: certificate
  verify failed`, `SSL error: received fatal alert: unknown_ca` for `tlsv1 alert unknown ca`. Everything libpq says
  in its own words is the same here.
- `sslAttribute(name: "library")` is `Mbed TLS`, and `cipher` is Mbed TLS's name for the suite.
- TLS 1.2 and 1.3 only. A minimum of TLSv1 or TLSv1.1 starts at 1.2; a maximum below 1.2 is libpq's `invalid value
  "…" for maximum SSL protocol version`.
- `sslrootcert=system` reads a CA bundle file: `SSL_CERT_FILE`, or the platform's (`/etc/ssl/cert.pem` on macOS).
  `SSL_CERT_DIR` is not read.
- No DES-encrypted keys (Mbed TLS has no DES) and no OpenSSL engines (`sslkey=engine:key` is refused). A key's
  passphrase comes from `sslpassword`; this client never prompts on a terminal.
- `sslkeylogfile` is created, or made, readable by its owner alone, and has no TLS 1.3 `EXPORTER_SECRET` line.
- `sslcrldir` loads every CRL file of the hashed directory up front, where OpenSSL opens them by issuer; the same
  chains pass.

## Transactions

A transaction is a borrow window. `transaction()` sends BEGIN, and the window ends the transaction when the block is
left by any path (its end, `return`, `break`, `continue`): ROLLBACK, unless it was committed. It is psycopg's
`with conn.transaction()` with no closure, because the window is the scope. The connection is frozen inside the
window, and `tx.conn()` reaches it:

```kama
fn Result<Unit, PgError> transfer(ref Connection conn, int64 cents) {
    borrow conn.transaction() as tx {
        Result<Unit, PgError> begun = tx.began();
        match (give begun) { case Ok(value: u): { } case Err(error: e): { return Result::Err(error: give e); } };
        Result<Optional<int64>, PgError> debit = tx.conn().execute(q: pg"update accounts set balance = balance - ${cents} where id = 1");
        match (give debit) { case Ok(value: n): { } case Err(error: e): { return Result::Err(error: give e); } };   // rolls back
        Result<Optional<int64>, PgError> credit = tx.conn().execute(q: pg"update accounts set balance = balance + ${cents} where id = 2");
        match (give credit) { case Ok(value: n): { } case Err(error: e): { return Result::Err(error: give e); } };
        return tx.commit();
    }
}
```

- **`tx.began()`** says whether BEGIN succeeded, since `transaction()` cannot return a Result. Check it first: a window
  whose transaction did not begin ends nothing, and statements sent through `tx.conn()` still run, outside a
  transaction.
- **`tx.commit()`** sends COMMIT; a COMMIT the server turns into a ROLLBACK, because the transaction had failed, is
  `PgError::RolledBack`. **`tx.rollback()`** sends ROLLBACK. **`tx.setOptions(options:)`** runs SET TRANSACTION with
  an isolation level, an access mode and DEFERRABLE, before the transaction's first query; the defaults send nothing.
- **A window inside a window is a savepoint**: `borrow tx.conn().transaction() as inner { … }` sends `SAVEPOINT sp_1`.
  `inner.commit()` releases it; a window that falls through rolls back to it and releases it, and the outer
  transaction goes on.
- **The transaction is over** once the view has committed or rolled it back, or once the server says the block
  ended, so a COMMIT sent through `tx.conn()` counts. A block chained in the same message (`COMMIT AND CHAIN`,
  `"COMMIT; BEGIN"`) belongs to the window, which rolls it back.
- **A window that cannot roll back closes the connection**, as pgx does, and logs a warning under the tag `postgres`.
  That happens when a COPY or pipeline mode is left open, or when the server refuses the ROLLBACK. The server rolls back
  the transaction of a session that ends, so a program that traps loses nothing it kept either.
- A helper takes the transaction as `ref Transaction`.

`begin(options:)`, `commit()` and `rollback()` run the same statements without a window. `savepoint()` gives a
`Savepoint` the connection names (`sp_1`, `sp_2`, …), for `releaseSavepoint(sp:)` and `rollbackToSavepoint(sp:)`.

```kama
TransactionOptions options = TransactionOptions.of(isolation: IsolationLevel::Serializable, access: AccessMode::ReadOnly, deferrable: true);
Result<Unit, PgError> begun = conn.begin(options: options);
// … queries …
Result<Unit, PgError> done = conn.commit();
```

## COPY

COPY runs as libpq runs it, and std::io drives it, as pgx's CopyFrom and CopyTo do:

```kama
Result<File, IoError> opened = File.open(path: "items.csv", mode: OpenMode::Read);
// … unwrap it into `file` …
Result<Optional<int64>, PgError> copied = conn.copyFrom(sql: "copy items (name, qty) from stdin (format csv)", source: file);
```

`copyTo(sql:, sink:)` writes COPY OUT to any `Writer`. The calls underneath are libpq's:

- `startCopyIn(sql)`, which gives a `CopyInfo` (binary or text, each column's format);
- `putCopyData(bytes:)`;
- `endCopyIn()`, with the rows copied, or `failCopyIn(reason:)`;
- `startCopyOut(sql)`, then `getCopyData()` until `CopyChunk::Done`.

Data goes out in 64 KiB writes. If the server has already failed the COPY, the next put stops it rather than sending
the rest.

## The statement cache

Each SQL text is prepared once, as a named statement, and bound directly after that. A repeated query then takes one
round trip instead of two. This is pgx's design, and it is on by default, with 512 statements kept and the least
recently used closed. It is set on the `Config`, since libpq has no keyword for it:

```kama
config.setStatementCache(mode: CacheMode::Describe, capacity: 512);   // for a pooler without named statements
```

The modes:

- `CacheMode::Describe` keeps only descriptions, and parses the unnamed statement on each run.
- `CacheMode::Off` describes before every run.

When the server refuses a cached plan because a table changed under it ("cached plan must not change result type"),
the entry is dropped. Outside a transaction the query runs again once, as pgjdbc does it; inside one, the error is
returned. DISCARD ALL and DEALLOCATE ALL empty the cache.

## Pipelines and batches

A `Batch` sends many queries in one round trip, and is pgx's SendBatch:

```kama
Batch batch = Batch.make();
batch.add(q: pg"insert into items (name, qty) values (${name}, 0)");
batch.add(q: pg"select count(*) from items");
Result<DynamicArray<BatchResult>, PgError> results = conn.runBatch(batch: batch);
```

Each query's result is `Rows`, `Failed` or `Aborted`. A failure aborts the queries after it, and the batch, which is
one implicit transaction, rolls back. Any SQL the cache does not know yet is described first, in a single round trip.

Underneath is libpq's pipeline mode, which is public:

- `enterPipelineMode()` and `exitPipelineMode()`;
- `sendQuery(q:)`, `sendPrepare(sql:)` and `sendClosePrepared(statement:)`;
- `pipelineSync()`, `sendPipelineSync()` and `sendFlushRequest()`;
- `getResult()`, which gives each command's `PipelineResult` in order.

After an error, each command up to the next sync is `Aborted`, as in libpq, and libpq's refusals are quoted word for
word. Seven of the nine traces of libpq's own `libpq_pipeline` test replay message for message.

## Cancel and timeouts

`conn.cancelToken()` gives a `CancelToken`, which is Sendable and can be copied. Another isolate uses it to cancel the
running command with `cancel()`. The request goes as libpq 17's does: to the same address, with the session's
`sslmode`, so it is encrypted when the session is.

A query timeout cancels and keeps the connection, as Npgsql and pgjdbc do:

```kama
conn.setQueryTimeout(timeout: Optional::Some(value: Duration.fromSecs(s: 30i64)), grace: Duration.fromSecs(s: 2i64));
```

When a call waits past the timeout, the command is cancelled, and the server's 57014 ("canceling statement due to user
request") is returned. The connection can then be used again. If the server does not answer within the grace period,
the connection is closed and the call returns `PgError::Timeout`. A connection made with `connectOver` has no way to
send a cancel, so it closes at the timeout.

## Checking and resetting a session

`conn.ping()` sends an empty query, as pgx's Ping does. The server answers it in a failed transaction block too. An
error means the session is gone.

`conn.resetSession()` returns the session to the state a new one starts in, so a connection can be handed to someone
else. It is Npgsql's reset, read from Npgsql 10.0.3's source:
- **An open transaction block is rolled back first.**
- **With nothing prepared, it sends `DISCARD ALL`.** "Prepared" means a named statement in the cache, or a `prepare()`
  not yet closed.
- **Otherwise it sends every part of DISCARD ALL except deallocating statements**, so the cache and prepared
  statements stay usable:

  ```sql
  SET SESSION AUTHORIZATION DEFAULT;RESET ALL;CLOSE ALL;UNLISTEN *;SELECT pg_advisory_unlock_all();DISCARD SEQUENCES;DISCARD TEMP
  ```
- **Older servers get what they support**, as Npgsql decides it. Below 8.3 there is no DISCARD, and only the rollback
  is done.

It takes one round trip. The rollback and the reset go in one write. Npgsql sends the reset in front of the
connection's next command instead. Here a failure is reported to whoever is resetting the session, and never lands on
the next command after that command has run. A reset that fails leaves the session half reset, so the connection is
closed and the error returned.

What it does not touch:
- **Notifications already received are dropped**, since `UNLISTEN *` undid the LISTENs they came from.
- **The notice handler and the query timeout stay as they are.** They are this client's settings, not the session's.

It is refused, as any command is, while a result, a COPY or pipeline mode is in progress.

## Notifications

`waitForNotification(timeout:)` returns the next LISTEN/NOTIFY notification. If none arrives in time it returns `None`,
and it takes in any notices on the way. libpq leaves this loop to the application, through PQsocket, PQconsumeInput
and PQnotifies.

## Limits

What a server can make one connection hold is bounded, where libpq bounds nothing. Each bound is set on the `Config`,
since libpq has no keyword for it, and each is an `Optional`: `None` turns it off.

```kama
Limits limits = Limits.defaults();
limits.resultBytes = Optional::Some(value: 64 * 1024 * 1024);   // fail a result over 64 MiB, and keep the session
config.setLimits(limits: limits);
```

| bound | default | past it |
|---|---|---|
| `readBuffer`: bytes taken in while a write waits | 1 GiB | the connection closes |
| `parameters`: distinct parameters the server reports | 1,000 | the connection closes |
| `notifications`: notifications waiting to be read | 10,000 | the oldest is dropped |
| `resultBytes`: row bytes one call keeps | off | the call fails, and the session goes on |

- **`readBuffer`.** This client reads while it writes, as libpq does, or a server answering a long pipeline would wait
  on the client while the client waits on it. A server that keeps sending while it takes nothing is a runaway.
- **`parameters`.** A server reports about twenty.
- **`notifications`.** A dropped notification is counted by `droppedNotifications()`, and the first since the queue
  was last read is logged as a warning under `postgres`. No other driver bounds this queue: libpq, pgjdbc and pgx let
  it grow, and Npgsql and asyncpg have none. PostgreSQL delivers a notification at most once, so a listener that must
  not miss an event already re-reads its state after a gap; this is one more kind of gap.
- **`resultBytes`** (pgjdbc's `maxResultBuffer`) counts the rows `query`, `simpleQuery` and `getResult` keep, a
  simple query's statements together and a batch's results together. Past it, the rest of the result is read and
  dropped, and the call returns `PgError::Limit` once the server is ready. The command ran, and the session and its
  transaction go on. Rows read a chunk at a time (`startRows`, a portal's `fetch`) are not counted: that is how to
  read a big result.

Reaching a bound is `PgError::Limit`, which names the bound, its value and what was given up.

## Several hosts

A connection string can list several hosts, as libpq's can:

- `target_session_attrs` takes any of `any`, `read-write`, `read-only`, `primary`, `standby` or `prefer-standby`. Each
  server is checked after login, the way libpq checks it, and one of the wrong kind is passed over for the next host.
- `load_balance_hosts=random` tries the hosts, and each host's addresses, in a random order.

## Where this differs from libpq

- **Query timeouts.** libpq has none; `statement_timeout` is the server's. This client's is the drivers' design,
  described above.
- **Bounds.** libpq bounds none of what a server can make it hold. This client does (see Limits), and refuses a
  pre-3.0 error with an empty text, which libpq reports as an empty error.
- **The cancel race.** A cancel can reach the server just after its command finished and the next one started. libpq
  documents the same race. This client narrows it as libpq does, by waiting for the server to close the cancel
  connection, but no client can close it entirely.
- **Text columns from pipelined SQL the cache has not seen.** Such a query goes as libpq's PQsendQueryParams sends it,
  so its columns come back as text, and `column::<T>` reads them from text. A query the cache knows goes typed.
- **Pipelines take no statement or portal names.** The two libpq_pipeline traces that name them are not replayed.

## What it covers

- **Connecting:**
  - TCP and Unix-domain sockets.
  - URI and `key=value` connection strings, `PG*` environment variables, `.pgpass` and
    `pg_service.conf`.
  - Multiple hosts with `target_session_attrs` and `load_balance_hosts`, connect timeouts, and TCP keepalive.
- **Security:**
  - TLS with every `sslmode` (`disable` … `verify-full`), `sslnegotiation=direct`, and client
    certificates.
  - SCRAM-SHA-256 and SCRAM-SHA-256-PLUS (channel binding), md5, cleartext, and `require_auth`.
- **Queries:**
  - Simple and extended protocol, typed parameters, and a `pg"… ${x}"` tag that parameterises
    interpolations (never splices them).
  - A statement cache.
  - Streaming rows, portals, pipelining and batches.
- **Data:** `column::<T>(row:, index:)` and `rowAs::<T>` into `@generate(Deserializable)` structs.
  Types are the built-ins plus numeric, interval, inet/cidr, arrays and ranges, with UUIDs and timestamps
  through `std::uuid` and `std::time`.
- **Everything else:**
  - Transactions and savepoints, COPY in and out, LISTEN/NOTIFY, query cancellation and timeouts.
  - `ping()`, and `resetSession()`, Npgsql's session reset.
  - Full `ErrorResponse` fields with SQLSTATE constants.
  - A connection pool shared across isolates (phase 8, not there yet).

No GSSAPI/Kerberos/SSPI: a server that asks for them gets a clear error.

## Tests

```sh
KAMA=/path/to/kama tools/test.sh               # hermetic unit tests, debug and release
KAMA=/path/to/kama tools/test-integration.sh   # live tests on PostgreSQL 14–18 and 19 beta, debug and release
tools/test-integration.sh --version 18         # one version
tools/pg.sh smoke --version 18                 # one login per auth and TLS method, with the server's own psql
tools/pg.sh down --version 18
```

The unit tests need no server. They include a scripted fake server that drives every startup and query path,
hostile ones included, and runs Mbed TLS as the server for the TLS paths. Every reply of eighteen conversations is
then changed in turn, ten ways, from a seed (`garble_test.kama`; `PGTEST_GARBLE_SEEDS=N` runs more): the client must
never panic, and a protocol error must end the session. The integration tests start each server in
podman or docker, and run the whole suite a second time over TLS. Their expected results come from libpq itself:
PostgreSQL's own authentication, service-file and TLS tests (its negotiation matrix and its host-name cases, replayed
by `tools/gen-ssl-vectors.sh`), and the server container's libpq asked case by case (`tools/gen-libpq-test-cases.sh`).

The pipeline tests replay the traces of libpq's own `libpq_pipeline` (`tools/gen-pipeline-vectors.sh`). The session
tests run the cases of PostgreSQL's `001_stream_rep.pl` and `003_load_balance_host_list.pl`
(`tools/gen-session-vectors.sh`).

The integration server has one role per authentication method and TLS on. A hot standby streams from each server,
for `target_session_attrs` and `load_balance_hosts`. Its test certificates are generated into `out/` and never
committed. See `tests/integration/server/`.

## License

`@kama/postgres` is licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. It vendors nothing; its TLS comes from `@kama/tls`, whose README says what that bundles.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in
`@kama/postgres` by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any
additional terms or conditions.
