#!/bin/sh
# test-integration.sh — the live tests (tests/integration) against each supported PostgreSQL, debug and release, and
# then once more in release over TLS (PGTEST_SSLMODE=require), so every query path runs encrypted too. Last, per
# version, the restart leg (PGTEST_RESTART=1): the cases that stop, start and restart the server through tools/pg.sh,
# run alone so that no other case meets a server going down. Then every example under examples/, debug in plaintext and
# release over TLS (sslmode=verify-full), each of which checks its own results.
#
#   tools/test-integration.sh                    every version: 14 15 16 17 18 19
#   tools/test-integration.sh --version 18 …     the versions named
#   tools/test-integration.sh --down …           remove each server when its run is done
#
# Each server is started (or reused) by tools/pg.sh, which writes its PGTEST_* settings; this script exports them
# and runs both builds against it. An example gets the server as a reader's program would, in libpq's PG* variables. `kama` is $KAMA or the PATH. When a case fails, `tools/pg.sh smoke --version N`
# tells a misconfigured server from a wrong client.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KAMA=${KAMA:-kama}
VERSIONS=""
DOWN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSIONS="$VERSIONS ${2:?--version needs a value}"; shift 2 ;;
        --down) DOWN=1; shift ;;
        *) echo "test-integration.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
[ -n "$VERSIONS" ] || VERSIONS="14 15 16 17 18 19"
tmp=$(mktemp -d)
# Unix sockets get a directory of their own under /tmp: a socket path is at most 103 bytes on macOS.
sockets=$(mktemp -d /tmp/kpg.XXXXXX)
trap 'rm -rf "$tmp" "$sockets"' EXIT

"$KAMA" pkg install "$ROOT/tests/integration/kama.json" >/dev/null
for mode in --debug --release; do
    "$KAMA" build "$ROOT/tests/integration/kama.json" $mode -o "$tmp/integration$mode" >/dev/null
done
EXAMPLES=""
for manifest in "$ROOT"/examples/*/kama.json; do
    name=$(basename "$(dirname "$manifest")")
    EXAMPLES="$EXAMPLES $name"
    "$KAMA" pkg install "$manifest" >/dev/null
    for mode in --debug --release; do "$KAMA" build "$manifest" $mode -o "$tmp/example-$name$mode" >/dev/null; done
done

failed=""
for v in $VERSIONS; do
    "$ROOT/tools/pg.sh" up --version "$v" >/dev/null
    for mode in --debug --release; do
        work="$tmp/work-$v$mode"; mkdir -p "$work/home"
        echo "== PostgreSQL $v ($mode)"
        if ( set -a; . "$ROOT/out/pgtest-$v.env"; set +a; PGTEST_TMP="$work" PGTEST_SOCKDIR="$sockets" "$tmp/integration$mode" ); then :; else failed="$failed $v$mode"; fi
    done
    work="$tmp/work-$v-tls"; mkdir -p "$work/home"
    echo "== PostgreSQL $v (--release, sslmode=require)"
    if ( set -a; . "$ROOT/out/pgtest-$v.env"; set +a; PGTEST_SSLMODE=require PGTEST_TMP="$work" PGTEST_SOCKDIR="$sockets" "$tmp/integration--release" ); then :; else failed="$failed $v-tls"; fi
    work="$tmp/work-$v-restart"; mkdir -p "$work/home"
    echo "== PostgreSQL $v (--release, restarts)"
    if ( set -a; . "$ROOT/out/pgtest-$v.env"; set +a; PGTEST_RESTART=1 PGTEST_PGSH="$ROOT/tools/pg.sh" PGTEST_TMP="$work" PGTEST_SOCKDIR="$sockets" "$tmp/integration--release" ); then :; else failed="$failed $v-restart"; fi
    # The leg leaves the server running; this makes sure, with its standby back in recovery.
    "$ROOT/tools/pg.sh" up --version "$v" >/dev/null
    # Each example runs from its own directory, as a reader runs it. It gets the server in libpq's PG* variables and
    # nothing else of this shell's environment, and HOME is a scratch directory, so no ~/.pgpass, service file or
    # ~/.postgresql of this machine's is read.
    for leg in --debug:disable --release:verify-full; do
        mode=${leg%%:*}; sslmode=${leg#*:}
        echo "== PostgreSQL $v examples ($mode, sslmode=$sslmode)"
        for name in $EXAMPLES; do
            work="$tmp/work-$v-$name$mode"; mkdir -p "$work"
            echo "-- $name"
            if ( set -a; . "$ROOT/out/pgtest-$v.env"; set +a; cd "$ROOT/examples/$name" &&
                 env -i PATH="$PATH" HOME="$work" PGHOST="$PGTEST_HOST" PGPORT="$PGTEST_PORT" PGDATABASE="$PGTEST_DATABASE" \
                     PGUSER=kp_trust PGSSLMODE="$sslmode" PGSSLROOTCERT="$PGTEST_CERTDIR/ca.crt" "$tmp/example-$name$mode" )
            then :; else failed="$failed $v-$name$mode"; fi
        done
    done
    [ "$DOWN" = 1 ] && "$ROOT/tools/pg.sh" down --version "$v" >/dev/null
done
if [ -n "$failed" ]; then echo "test-integration.sh: FAILED on$failed" >&2; exit 1; fi
echo "test-integration.sh: OK on$(printf ' %s' $VERSIONS)"
