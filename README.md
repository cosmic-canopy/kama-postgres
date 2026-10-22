# @kama/postgres

The PostgreSQL client for [kama](https://kama-lang.org). It speaks the PostgreSQL v3 wire protocol directly,
in kama, over `std::net`, the way pgx, tokio-postgres, pgjdbc and Npgsql do. There is no libpq and nothing to
install. TLS comes from [`@kama/tls`](https://github.com/cosmic-canopy/kama-tls).

```sh
kama pkg add kama.json @kama/postgres --version ^0.2.0     # from the official registry, registry.kama-lang.org
```

Needs **kama ≥ 0.9.690**, declared in the manifest, so an older compiler is refused by name. Tested, debug and
release, on macOS arm64 and Linux, against PostgreSQL 14–18 and 19 beta.

> **Status: early.** It connects, authenticates and runs queries, with typed parameters and typed rows, over TCP, a
> Unix-domain socket or TLS (every `sslmode`, client certificates, SCRAM-SHA-256-PLUS). The statement cache,
> transactions and savepoints, COPY, waiting for notifications, pipelining and batches, cancellation and query timeouts,
> `target_session_attrs` and `load_balance_hosts` came in 0.2.0, and a pool shared by isolates is coming in 0.3.0. See [docs/ROADMAP.md](docs/ROADMAP.md). In 0.x, a minor version may break the API.

## Using it

```kama
import { core::args, core::println, std::collections::DynamicArray,
         postgres::Config, postgres::Connection, postgres::PgError, postgres::Rows, postgres::column,
         postgres::columnOpt };

fn uint8 main() {
    // A libpq connection string; the service file, PG* variables and ~/.pgpass apply as they do for psql.
    Optional<string> given = args().get(at: 0);
    string conninfo = match (give given) { case Some(value: s): give s; case None: ""; };
    Result<Config, PgError> parsed = Config.parse(text: conninfo);
    Config config = match (give parsed) { case Ok(value: c): give c; case Err(error: e): { println(s: e.message()); return 1; } };
    Result<Connection, PgError> opened = Connection.connect(config: config);
    Connection conn = match (give opened) { case Ok(value: c): give c; case Err(error: e): { println(s: e.message()); return 1; } };

    bool encrypted = conn.sslInUse();
    Optional<string> protocol = conn.sslAttribute(name: "protocol");   // "TLSv1.3"
    string version = match (give protocol) { case Some(value: p): give p; case None: "none"; };
    println(s: "encrypted: ${encrypted} (${version})");

    // A simple query may hold several statements, and gives one Rows for each.
    string sql = "create temp table items (name text, qty int4);"
        .concat(other: "insert into items values ('bolt', 12), ('nut', 40), (null, 3);")
        .concat(other: "select name, qty from items order by qty");
    Result<DynamicArray<Rows>, PgError> r = conn.simpleQuery(sql: sql);
    DynamicArray<Rows> results = match (give r) { case Ok(value: v): give v; case Err(error: e): { println(s: e.message()); return 1; } };
    string listed = "";
    isize i = 0;
    while (i < results[2].rowCount()) {
        // Typed access, as PQgetvalue addresses a value: the result, the row, the column. NULL reads only into an Optional.
        Result<Optional<string>, PgError> name = columnOpt::<string>(rows: results[2], row: i, index: 0);
        Result<int32, PgError> qty = column::<int32>(rows: results[2], row: i, index: 1);
        Optional<string> named = match (give name) { case Ok(value: n): give n; case Err(error: e): { println(s: e.message()); return 1; } };
        int32 count = match (qty) { case Ok(value: q): q; case Err(error: e): { println(s: e.message()); return 1; } };
        string shown = match (give named) { case Some(value: s): give s; case None: "(no name)"; };
        println(s: "${shown}: ${count}");
        if (i > 0) { listed = listed.concat(other: ", "); }
        listed = listed.concat(other: "${shown} ${count}");
        i = i + 1;
    }
    conn.close();
    if (!listed.equals(other: "(no name) 3, bolt 12, nut 40")) { println(s: "expected (no name) 3, bolt 12, nut 40"); return 1; }
    return 0;
}
```

That is [`examples/quickstart`](https://github.com/cosmic-canopy/kama-postgres/blob/main/examples/quickstart/src/main.kama),
and every code block in this README comes from one of the [examples](#examples), each of which has run against every
server this package is tested on.

Parameters go through the extended protocol, with the `pg` tag or a `Query`. A hole is always a parameter, never
text in the SQL. Holes are typed: an empty `Optional` is NULL, and a `DynamicArray<uint8>` is bytea:

```kama
int32 least = 5;
Optional<string> supplier = Optional::None;
Query q = pg"select name, qty, supplier, tags from items where qty > ${least} and supplier is not distinct from ${supplier}";
Result<Rows, PgError> r = conn.query(q: q);
```

`rowAs::<T>` reads a row into a `@generate(Deserializable)` type by column name:

```kama
@generate(Deserializable)
type resource Item {
    @field string name;
    @field(name: "qty") int32 quantity;
    @field Optional<string> supplier;
    @field DynamicArray<string> tags;
    @field(default) string unit = "each";

    public const fn string described() {
        string from = match (this.supplier) { case Some(value: s): copy s; case None: "anyone"; };
        isize tagged = this.tags.length();
        return "${this.name}: ${this.quantity} ${this.unit} from ${from}, ${tagged} tags";
    }
}

// The row as an Item, described; or the error's message.
unsafe fn string itemAt(const ref Rows rows, isize row) {
    Result<Item, PgError> item = rowAs::<Item>(rows: rows, row: row);
    return match (item) { case Ok(value: x): x.described(); case Err(error: e): e.message(); };
}
```

A row or a column also reads into std's `JsonValue`, when its shape is not known in advance. `prepare` gives a reusable
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

```sh
kama run examples/quickstart/kama.json -- "host=db.internal dbname=inventory user=app sslmode=verify-full sslrootcert=/etc/pg/ca.crt"
```

The quickstart then reads back what the session negotiated:

```kama
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
// Moves `cents` from account 1 to account 2, or nothing at all.
unsafe fn Result<Unit, PgError> transfer(ref Connection conn, int64 cents) {
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
match (give begun) { case Ok(value: u): { } case Err(error: e): { println(s: e.message()); return 1; } };
Result<Rows, PgError> total = conn.query(q: pg"select sum(balance)::int8 from accounts");
Result<Unit, PgError> done = conn.commit();
```

## COPY

COPY runs as libpq runs it, and std::io drives it, as pgx's CopyFrom and CopyTo do:

```kama
Result<File, IoError> opened = File.open(path: "items.csv", mode: OpenMode::Read);
File file = match (give opened) { case Ok(value: f): give f; case Err(error: e): { println(s: e.message()); return 1; } };
Result<Optional<int64>, PgError> copied = conn.copyFrom(sql: "copy items (name, qty, supplier) from stdin (format csv, header true)", source: file);
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
recently used closed. It is set on the `Config`, since libpq has no keyword for it, with
`config.setStatementCache(mode:, capacity:)`. The modes:

- `CacheMode::Describe` keeps only descriptions, and parses the unnamed statement on each run.
- `CacheMode::Off` describes before every run.

When the server refuses a cached plan because a table changed under it ("cached plan must not change result type"),
the entry is dropped. Outside a transaction the query runs again once, as pgjdbc does it; inside one, the error is
returned. DISCARD ALL and DEALLOCATE ALL empty the cache.

## Pipelines and batches

A `Batch` sends many queries in one round trip, and is pgx's SendBatch:

```kama
Batch batch = Batch.make();
isize i = 0;
while (i < names.length()) {
    string name = copy names[i];
    batch.add(q: pg"insert into items (name, qty) values (${name}, 0)");
    i = i + 1;
}
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

## A pool

`postgres::pool` keeps connections for the isolates of a program to share, as pgxpool, HikariCP and Npgsql keep theirs.

```kama
PoolOptions options = PoolOptions.defaults();
options.maxSize = 2;
options.minIdle = 1;   // the maintenance keeps one connection ready
Result<Pool, PgError> made = Pool.make(config: config, options: options);
Pool pool = match (give made) { case Ok(value: p): give p; case Err(error: e): { println(s: e.message()); return 1; } };
```

`acquire()` returns a `Lease`, and the lease gives its connection back when it is dropped, on every path out of its
scope. `lease.conn()` is the connection: pass it wherever a `ref Connection` goes, or open a transaction window on it.

```kama
unsafe fn int32 job(ref Pool pool) {
    Result<Lease, PgError> got = pool.acquire();
    Lease lease = match (give got) { case Ok(value: l): give l; case Err(error: e): { println(s: e.message()); return -1; } };
    borrow lease.conn().transaction() as tx {
        Result<Unit, PgError> begun = tx.began();
        match (give begun) { case Ok(value: u): { } case Err(error: e): { println(s: e.message()); return -1; } };
        Result<Rows, PgError> r = tx.conn().query(q: pg"select pg_backend_pid() from pg_advisory_xact_lock(42)");
        Rows rows = match (give r) { case Ok(value: v): give v; case Err(error: e): { println(s: e.message()); return -1; } };
        Result<int32, PgError> backend = column::<int32>(rows: rows, row: 0, index: 0);
        int32 pid = match (backend) { case Ok(value: p): p; case Err(error: e): { println(s: e.message()); return -1; } };
        Result<Unit, PgError> done = tx.commit();
        match (give done) { case Ok(value: u): { } case Err(error: e): { println(s: e.message()); return -1; } };
        return pid;
    }
}
```

A pool belongs to the isolate that made it. To use it from another, `pool.share()` makes a `PoolShare`, which is
`Sendable`, and `Pool.join(share:)` in that isolate makes a pool over the same connections, with the same maxSize
between them all. Only the pool that made the connections' channels can share them.

```kama
Result<PoolShare, PgError> shared = pool.share();
PoolShare share = match (give shared) { case Ok(value: s): give s; case Err(error: e): { println(s: e.message()); return 1; } };
Worker w = Worker.make(share: give share, report: answers.sender());
Isolate t = spawn work(w: give w);
```

- **The bound.** At most `maxSize` connections are open at once, leased and idle together, across every isolate. A
  connection is made when one is acquired and none is idle, or by the maintenance to keep `minIdle`. One acquire at a
  time keeps using one connection.
- **Waiting.** While every connection is leased, `acquire()` waits for one to come back, up to `acquireTimeout`, and
  then fails with `PgError::PoolTimeout`. A connect that fails is acquire's error, and its place in the pool is given
  back.
- **Release.** A connection that is closed, busy (a result, a stream or a COPY still open) or in pipeline mode is
  closed, not kept. Otherwise its session is reset (`resetSession()`, above), which rolls back an open transaction
  block, and a reset that fails closes the connection. With `reset` off, only an open block is rolled back, as pgx does.
  The pool's query timeout is put back, and a notice handler set through the lease is cleared.
- **Lifetime.** A connection is closed once it has been open for `lifetime`, plus a random part of `lifetimeJitter`, so
  that connections made together are not all replaced together.
- **Pings.** Acquire pings an idle connection last known to be alive more than a second ago, within `pingTimeout`. One
  that does not answer (its server restarted, or ended the session) is closed, and the next idle one is taken.
- **Maintenance.** The pool that made the connections runs an isolate of its own, every `healthCheck`, and stops it
  when that pool is dropped. It does four things:
  - it closes connections past their lifetime;
  - it pings the idle ones;
  - it connects until `minIdle` connections are idle;
  - it closes the connections the pool has not needed, as Npgsql prunes. Each round records how many connections are
    idle. Once `idleTimeout` has been recorded, the median of those counts is closed, never leaving fewer than
    `minIdle`. A pool that grew in a burst shrinks to what its traffic uses, even while that traffic goes on.

The defaults are pgxpool's where pgxpool has one:
- `maxSize` max(4, the CPUs online);
- a `lifetime` of one hour;
- `minIdle` 0;
- an `idleTimeout` of 30 minutes;
- a `healthCheck` of one minute.

The rest come from other pools:
- a `lifetimeJitter` of 90 seconds (HikariCP's 2.5%);
- a `pingTimeout` of 5 seconds (HikariCP's validationTimeout);
- an `acquireTimeout` of 30 seconds (sqlx's and HikariCP's);
- `reset` on (Npgsql's and asyncpg's).

`Pool.makeWith(connector:, config:, options:)` takes a `Connector` that makes the connections, for a pool that connects
through a `Dialer` or sets each session up its own way.

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

## When the server restarts

A session open across a restart is over. Its next call fails with what libpq reports in its place:

- the server's own `FATAL:  terminating connection due to administrator command` (57P01), when it arrived before the
  connection closed, as it usually does in a fast shutdown;
- otherwise `PgError::Lost`, in libpq's words: "server closed the connection unexpectedly…" for a server that hung up,
  "could not receive data from server: …" or "could not send data to server: …" with the operating system's words for
  anything else;
- over TLS, "SSL connection has been closed unexpectedly", or "SSL SYSCALL error: EOF detected".

`isClosed()` is then true, and every later call is `PgError::Closed`. A pool reads `isClosed()` to drop such a
connection. A connect while the server is down fails as libpq's does ("Connection refused" and its hint), and with
several hosts it goes on to the next one. While the server starts, a connect may meet "the database system is starting
up" (57P03), which also moves on to the next host. The integration suite restarts each server to check all of this, in
plaintext and over TLS.

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
  - A connection pool shared across isolates.

No GSSAPI/Kerberos/SSPI: a server that asks for them gets a clear error.

## Examples

Each is a program of its own under [`examples/`](https://github.com/cosmic-canopy/kama-postgres/tree/main/examples).
Each takes a connection string as its argument, or reads libpq's `PG*` variables when given none, as psql does:

```sh
kama pkg install examples/quickstart/kama.json
PGHOST=localhost PGUSER=app PGDATABASE=inventory kama run examples/quickstart/kama.json
kama run examples/quickstart/kama.json -- "postgresql://app@db.internal/inventory"
```

- [`quickstart`](https://github.com/cosmic-canopy/kama-postgres/blob/main/examples/quickstart/src/main.kama): connect,
  run a simple query of several statements, read typed values and a NULL, and show the TLS the session negotiated.
- [`typed_rows`](https://github.com/cosmic-canopy/kama-postgres/blob/main/examples/typed_rows/src/main.kama): the `pg`
  tag's typed holes (NULL, an array), a row into a `@generate(Deserializable)` type and into std's `JsonValue`, and a
  bound on a result's size.
- [`transactions`](https://github.com/cosmic-canopy/kama-postgres/blob/main/examples/transactions/src/main.kama): a
  transfer in a transaction window, committed whole or rolled back whole; a savepoint window that rolls back alone; and
  a read-only serializable transaction without a window.
- [`copy_csv`](https://github.com/cosmic-canopy/kama-postgres/blob/main/examples/copy_csv/src/main.kama): a CSV file
  in with COPY FROM, and the table out again with COPY TO. Run it from its own directory, where its `items.csv` is.
- [`notify_worker`](https://github.com/cosmic-canopy/kama-postgres/blob/main/examples/notify_worker/src/main.kama): a
  worker that waits for LISTEN/NOTIFY jobs sent from another isolate, each job bounded by a query timeout.
- [`shared_pool`](https://github.com/cosmic-canopy/kama-postgres/blob/main/examples/shared_pool/src/main.kama): one
  pool shared by four worker isolates, a transaction per job, and never more sessions than `maxSize`.
- [`batch`](https://github.com/cosmic-canopy/kama-postgres/blob/main/examples/batch/src/main.kama): queries in one
  round trip, and a batch that fails halfway and rolls back.

Each one checks what it reads back, and exits 1 if anything is wrong. The tables they make are temporary, so they need
no privilege beyond connecting. `tools/test.sh` builds them, and `tools/check-readme.sh` holds every code block in this
README to one of them. `tools/test-integration.sh` runs them against every server, in plaintext and over TLS with
`sslmode=verify-full`.

## Tests

```sh
KAMA=/path/to/kama tools/test.sh               # hermetic unit tests debug and release, the examples built, the README checked
KAMA=/path/to/kama tools/test-integration.sh   # live tests on PostgreSQL 14–18 and 19 beta, debug and release, then the examples
tools/test-integration.sh --version 18         # one version
tools/pg.sh smoke --version 18                 # one login per auth and TLS method, with the server's own psql
tools/pg.sh restart --version 18               # also stop and start: the server keeps its data
tools/pg.sh down --version 18
```

The unit tests need no server. They include a scripted fake server that drives every startup and query path,
hostile ones included, and runs Mbed TLS as the server for the TLS paths. Every reply of eighteen conversations is
then changed in turn, ten ways, from a seed (`garble_test.kama`; `PGTEST_GARBLE_SEEDS=N` runs more): the client must
never panic, and a protocol error must end the session. The integration tests start each server in
podman or docker, run the whole suite a second time over TLS, and then restart, stop and start each server around the
sessions of a last leg of their own. Their expected results come from libpq itself:
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
