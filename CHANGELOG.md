# Changelog

All notable changes to this package are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions follow
[SemVer](https://semver.org/). In 0.x, a minor bump may break.

## [Unreleased]

Needs **kama ≥ 0.9.486**.

### Added
- The package scaffold: manifest, agent files, hermetic unit-test program (`tools/test.sh`).
- The integration server: `tools/pg.sh` runs the official PostgreSQL image (14–18, 19 beta) under podman or
  docker with TLS on and one role per authentication method; `tools/gen-test-certs.sh` generates its
  throwaway PKI. `tools/pg.sh smoke` passes on 14.24, 15.19, 16.15, 17.11, 18.4 and 19beta4.
