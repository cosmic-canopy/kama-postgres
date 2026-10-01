#!/bin/sh
# test-integration.sh — the live tests (tests/integration) against each supported PostgreSQL, debug and release.
#
#   tools/test-integration.sh                    every version: 14 15 16 17 18 19
#   tools/test-integration.sh --version 18 …     the versions named
#   tools/test-integration.sh --down …           remove each server when its run is done
#
# Each server is started (or reused) by tools/pg.sh, which writes its PGTEST_* settings; this script exports them
# and runs both builds against it. `kama` is $KAMA or the PATH. When a case fails, `tools/pg.sh smoke --version N`
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

failed=""
for v in $VERSIONS; do
    "$ROOT/tools/pg.sh" up --version "$v" >/dev/null
    for mode in --debug --release; do
        work="$tmp/work-$v$mode"; mkdir -p "$work/home"
        echo "== PostgreSQL $v ($mode)"
        if ( set -a; . "$ROOT/out/pgtest-$v.env"; set +a; PGTEST_TMP="$work" PGTEST_SOCKDIR="$sockets" "$tmp/integration$mode" ); then :; else failed="$failed $v$mode"; fi
    done
    [ "$DOWN" = 1 ] && "$ROOT/tools/pg.sh" down --version "$v" >/dev/null
done
if [ -n "$failed" ]; then echo "test-integration.sh: FAILED on$failed" >&2; exit 1; fi
echo "test-integration.sh: OK on$(printf ' %s' $VERSIONS)"
