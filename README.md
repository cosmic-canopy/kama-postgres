# @kama/postgres

The PostgreSQL client for [kama](https://kama-lang.org). It speaks the PostgreSQL v3 wire protocol directly,
in kama, over `std::net`, the way pgx, tokio-postgres, pgjdbc and Npgsql do. There is no libpq and nothing to
install. TLS comes from [`@kama/tls`](https://github.com/cosmic-canopy/kama-tls).

> **Status: under construction, not yet published.** The scaffold, the test server and the compiler
> prerequisites are in place. The client itself is being built in the order in
> [docs/ROADMAP.md](docs/ROADMAP.md). Needs **kama ≥ 0.9.486**.

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
KAMA=/path/to/kama tools/test.sh          # hermetic unit tests, debug and release
tools/pg.sh up --version 18               # a real PostgreSQL in podman or docker (14–18, 19 beta)
tools/pg.sh smoke --version 18            # one login per auth method, with the server's own psql
tools/pg.sh down --version 18
```

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
