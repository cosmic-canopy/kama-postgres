# Changelog

All notable changes to this package are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions follow
[SemVer](https://semver.org/). In 0.x, a minor bump may break.

## [Unreleased]

Needs **kama ≥ 0.9.486**.

### Changed
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
- Generators, each pinned to its source by SHA256 and reproducible: `tools/gen-auth-vectors.sh`,
  `tools/gen-libpq-tables.sh`, `tools/gen-pg-catalog.sh`, `tools/gen-codec-vectors.sh`.
- The package scaffold: manifest, agent files, hermetic unit-test program (`tools/test.sh`).
- The integration server: `tools/pg.sh` runs the official PostgreSQL image (14–18, 19 beta) under podman or
  docker with TLS on and one role per authentication method; `tools/gen-test-certs.sh` generates its
  throwaway PKI. `tools/pg.sh smoke` passes on 14.24, 15.19, 16.15, 17.11, 18.4 and 19beta4.
