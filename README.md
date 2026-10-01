# @kama/postgres

The PostgreSQL client for [kama](https://kama-lang.org). It speaks the PostgreSQL v3 wire protocol directly,
in kama, over `std::net`, the way pgx, tokio-postgres, pgjdbc and Npgsql do. There is no libpq and nothing to
install. TLS comes from [`@kama/tls`](https://github.com/cosmic-canopy/kama-tls).

> **Status: under construction, not yet published.** It connects, authenticates and runs queries, with typed
> parameters and typed rows, on PostgreSQL 14–18 and 19 beta, over TCP or a Unix-domain socket. TLS comes next; see
> [docs/ROADMAP.md](docs/ROADMAP.md). Needs **kama ≥ 0.9.506**.

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
text in the SQL:

```kama
Query q = pg"select name, qty from items where qty > ${least} order by name";
Result<Rows, PgError> r = conn.query(q: q);
```

`rowAs::<T>` reads a row into a `@generate(Deserializable)` type by column name. `prepare` gives a reusable
`Statement`. `startRows`/`nextRows` read a large result a chunk at a time, and `openPortal`/`fetch` read a
cursor inside a transaction.

A server error is `PgError::Server` with every field PostgreSQL sends. Compare `e.sqlstate()` with the
constants in `postgres::sqlstate`. Messages read as psql prints them. With no `NoticeHandler` set, notices go
to `std::log` under the tag `postgres`.

## What it will cover

- **Connecting:**
  - TCP and Unix-domain sockets.
  - URI and `key=value` connection strings, `PG*` environment variables, `.pgpass` and
    `pg_service.conf`.
  - Multiple hosts with `target_session_attrs`, connect timeouts, and TCP keepalive.
- **Security:**
  - TLS with every `sslmode` (`disable` … `verify-full`), `sslnegotiation=direct`, and client
    certificates.
  - SCRAM-SHA-256 and SCRAM-SHA-256-PLUS (channel binding), md5, cleartext, and `require_auth`.
- **Queries:**
  - Simple and extended protocol, typed parameters, and a `pg"… ${x}"` tag that parameterises
    interpolations (never splices them).
  - Prepared-statement caching.
  - Streaming rows, portals, and pipelining.
- **Data:** `column::<T>(row:, index:)` and `rowAs::<T>` into `@generate(Deserializable)` structs.
  Types are the built-ins plus numeric, interval, inet/cidr, arrays and ranges, with UUIDs and timestamps
  through `std::uuid` and `std::time`.
- **Everything else:**
  - Transactions and savepoints, COPY in and out, LISTEN/NOTIFY, query cancellation and timeouts.
  - Full `ErrorResponse` fields with SQLSTATE constants.
  - A connection pool shared across isolates.

No GSSAPI/Kerberos/SSPI: a server that asks for them gets a clear error.

## Tests

```sh
KAMA=/path/to/kama tools/test.sh               # hermetic unit tests, debug and release
KAMA=/path/to/kama tools/test-integration.sh   # live tests on PostgreSQL 14–18 and 19 beta, debug and release
tools/test-integration.sh --version 18         # one version
tools/pg.sh smoke --version 18                 # one login per auth method, with the server's own psql
tools/pg.sh down --version 18
```

The unit tests need no server. They include a scripted fake server that drives every startup and query path,
hostile ones included. The integration tests start each server in podman or docker. Their expected results
come from libpq itself: PostgreSQL's own authentication and service-file tests, and the server container's
libpq asked case by case (`tools/gen-libpq-test-cases.sh`).

The integration server has one role per authentication method and TLS on. Its test certificates are
generated into `out/` and never committed. See `tests/integration/server/`.

## License

`@kama/postgres` is licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. It vendors nothing; its TLS comes from `@kama/tls`, whose README says what that bundles.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in
`@kama/postgres` by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any
additional terms or conditions.
