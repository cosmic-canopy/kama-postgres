#!/bin/sh
# seed-kama-store.sh — KPG-46's workaround, for Windows. kama 0.9.719's `pkg install` cannot unpack a registry tarball
# there: its tar command fails under Git's GNU tar, msys2's and Windows' bsdtar alike. So each registry package a
# kama.lock here pins is put into kama's store as kama would put it: the tarball checked against the lock's integrity,
# then unpacked by this shell's tar into <store>/<label>-<tree hash>. kama finds that entry and unpacks nothing.
# Delete this, and its CI step, once KPG-46 is fixed.
#
#   tools/seed-kama-store.sh       every kama.lock: the package's, the tests' and the examples'
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
store=${KAMA_STORE:-$HOME/.kama/store}
mkdir -p "$store"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

for lock in "$ROOT/kama.lock" "$ROOT"/tests/*/kama.lock "$ROOT"/examples/*/kama.lock; do
    [ -f "$lock" ] || continue
    # One package per line, as kama writes a lock.
    grep -o '"@[^"]*": { "source": "registry"[^}]*}' "$lock" | while IFS= read -r entry; do
        name=$(printf '%s' "$entry" | sed 's/^"\([^"]*\)".*/\1/')
        url=$(printf '%s' "$entry" | sed 's/.*"url": "\([^"]*\)".*/\1/')
        integrity=$(printf '%s' "$entry" | sed 's/.*"integrity": "sha256-\([0-9a-f]*\)".*/\1/')
        tree=$(printf '%s' "$entry" | sed 's/.*"treeHash": "sha256-\([0-9a-f]*\)".*/\1/')
        dir="$store/$(printf '%s' "$name" | tr '/' '_')-$tree"
        [ -d "$dir" ] && continue
        curl -fsSL -o "$tmp/package.tgz" "$url"
        got=$(sha256sum "$tmp/package.tgz" | cut -d' ' -f1)
        [ "$got" = "$integrity" ] || { echo "seed-kama-store: $name from $url has sha256 $got, want $integrity" >&2; exit 1; }
        rm -rf "$dir.seeding"; mkdir -p "$dir.seeding"
        tar -xzf "$tmp/package.tgz" -C "$dir.seeding" --strip-components=1
        mv "$dir.seeding" "$dir"
        echo "seed-kama-store: $name into $(basename "$dir")"
    done
done
