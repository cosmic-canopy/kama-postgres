#!/bin/sh
# test.sh — build and run the hermetic unit tests, debug then release; build every example, debug and release; and
# check that each code block in README.md is code from an example (tools/check-readme.sh). `kama` is taken from $KAMA
# or the PATH. The integration suite and the examples need a live server, and have their own runner:
# tools/test-integration.sh.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KAMA=${KAMA:-kama}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A fresh checkout has no .kama/deps: install what kama.lock pins (from the registry, or a kama.local.json override).
"$KAMA" pkg install "$ROOT/kama.json" >/dev/null
"$KAMA" check "$ROOT/kama.json"
# The TLS cases run Mbed TLS against the test PKI (generated, never tracked), and write key copies to a scratch dir.
"$ROOT/tools/gen-test-certs.sh" >/dev/null
PGTEST_CERTDIR="$ROOT/out/test-certs"; export PGTEST_CERTDIR
PGTEST_TMP="$tmp/scratch"; mkdir -p "$PGTEST_TMP"; export PGTEST_TMP
"$KAMA" pkg install "$ROOT/tests/unit/kama.json" >/dev/null
for mode in --debug --release; do
    "$KAMA" build "$ROOT/tests/unit/kama.json" $mode -o "$tmp/unit$mode"
    "$tmp/unit$mode"
done
# The examples build, debug and release; tools/test-integration.sh runs them against each server. Each has its own
# kama.lock, which pins the newest @kama/tls this package's range admits, as a consumer's would.
for manifest in "$ROOT"/examples/*/kama.json; do
    "$KAMA" pkg install "$manifest" >/dev/null
    for mode in --debug --release; do "$KAMA" build "$manifest" $mode -o "$tmp/example" >/dev/null; done
done
"$ROOT/tools/check-readme.sh"
echo "test.sh: OK"
