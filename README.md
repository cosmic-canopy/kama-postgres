# @kama/postgres

The PostgreSQL client for [kama](https://kama-lang.org). It speaks the PostgreSQL v3 wire protocol directly,
in kama, over `std::net`, the way pgx, tokio-postgres, pgjdbc and Npgsql do. There is no libpq and nothing to
install. TLS comes from [`@kama/tls`](https://github.com/cosmic-canopy/kama-tls).

```sh
kama pkg add kama.json @kama/postgres --version ^0.1.0     # from the official registry, registry.kama-lang.org
```

Needs **kama ≥ 0.9.523**, declared in the manifest, so an older compiler is refused by name. Tested, debug and
release, on macOS arm64 and Linux, against PostgreSQL 14–18 and 19 beta.

> **Status: 0.1.0, early.** It connects, authenticates and runs queries, with typed parameters and typed rows, over
> TCP, a Unix-domain socket or TLS (every `sslmode`, client certificates, SCRAM-SHA-256-PLUS). Not there yet: the
> statement cache, helpers for transactions (plain `begin`/`commit` statements work), COPY, waiting for
> notifications, pipelining, cancellation and query timeouts, `target_session_attrs`, `load_balance_hosts`, and a
> pool. See [docs/ROADMAP.md](docs/ROADMAP.md). In 0.x, a minor version may break the API.

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

`rowAs::<T>` reads a row into a `@generate(Deserializable)` type by column name. `prepare` gives a reusable
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
tools/pg.sh smoke --version 18                 # one login per auth and TLS method, with the server's own psql
tools/pg.sh down --version 18
```

The unit tests need no server. They include a scripted fake server that drives every startup and query path,
hostile ones included, and runs Mbed TLS as the server for the TLS paths. The integration tests start each server in
podman or docker, and run the whole suite a second time over TLS. Their expected results come from libpq itself:
PostgreSQL's own authentication, service-file and TLS tests (its negotiation matrix and its host-name cases, replayed
by `tools/gen-ssl-vectors.sh`), and the server container's libpq asked case by case (`tools/gen-libpq-test-cases.sh`).

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
