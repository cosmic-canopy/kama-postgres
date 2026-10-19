#!/bin/sh
# mutate.sh — the gate's last check, that a test is good: each mutation of the source must make the case it targets
# fail. A test that passes on broken code proves nothing, so every step of a phase runs its mutations before it commits.
#
#   tools/mutate.sh tools/mutations/s0b.json                  every unit mutation in the file
#   tools/mutate.sh tools/mutations/s0b.json M3 M7            only those
#   tools/mutate.sh tools/mutations/s0b.json --version 18     the integration mutations too, against PostgreSQL 18
#
# A mutation file is a JSON list. Each entry is
#   {"id": "M1", "suite": "unit" | "integration", "file": "src/…", "old": "…", "new": "…", "expect": "…"}
# and `old` must occur exactly once in `file`. `expect` is part of the check's name (what `check` prints after FAIL),
# or PANICKED for a mutation the program must die of. An entry may add "env": {"NAME": "value", …} for its run.
#
# The tree is copied to a scratch directory (without .git and out/), so the working tree is never touched. For each
# mutation, the copy's file is changed, the suite is built in debug and run, and the file is put back. The verdict:
#   CAUGHT            the targeted case failed;
#   FAILED-ELSEWHERE  other cases failed, not that one (strengthen the targeted case);
#   SURVIVED          nothing failed;
#   PANICKED          the program died (a panic, a signal) before any case failed, and `expect` is not PANICKED;
#   BAD-PATTERN       `old` is not in the file exactly once (the source moved on: update the mutation);
#   BUILD-FAILED      the mutation does not compile.
# It exits 1 unless every mutation run is CAUGHT. `kama` is $KAMA or the PATH; an integration run needs the server up
# (tools/pg.sh up --version N) and reads its out/pgtest-N.env.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KAMA=${KAMA:-kama}
[ $# -ge 1 ] || { echo "usage: tools/mutate.sh <mutations.json> [--version N] [id …]" >&2; exit 2; }
FILE=$1; shift
VERSION=""
IDS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=${2:?--version needs a value}; shift 2 ;;
        *) IDS="$IDS $1"; shift ;;
    esac
done
tmp=$(mktemp -d)
sockets=$(mktemp -d /tmp/kpgm.XXXXXX)   # a socket path is at most 103 bytes on macOS
trap 'rm -rf "$tmp" "$sockets"' EXIT

"$ROOT/tools/gen-test-certs.sh" >/dev/null
rsync -a --exclude .git --exclude out "$ROOT/" "$tmp/tree/"
"$KAMA" pkg install "$tmp/tree/tests/unit/kama.json" >/dev/null
[ -z "$VERSION" ] || "$KAMA" pkg install "$tmp/tree/tests/integration/kama.json" >/dev/null
envfile=""
[ -z "$VERSION" ] || envfile="$ROOT/out/pgtest-$VERSION.env"
# The restart group drives the real servers' tools/pg.sh; an entry runs it with "env": {"PGTEST_RESTART": "1"}.
PGTEST_PGSH="$ROOT/tools/pg.sh"; export PGTEST_PGSH

python3 -I - "$tmp" "$KAMA" "$ROOT/$FILE" "$ROOT/out/test-certs" "$envfile" "$sockets" $IDS <<'PY'
import json, os, subprocess, sys, tempfile
tmp, kama, path, certs, envfile, sockets = sys.argv[1:7]
only = set(sys.argv[7:])
tree = os.path.join(tmp, "tree")
env = dict(os.environ, PGTEST_CERTDIR=certs)
if envfile:
    for line in open(envfile):
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = v
missed = 0
for m in json.load(open(path)):
    if only and m["id"] not in only:
        continue
    if m["suite"] == "integration" and not envfile:
        continue
    target = os.path.join(tree, m["file"])
    src = open(target).read()
    n = src.count(m["old"])
    if n != 1:
        print(f"{m['id']}: BAD-PATTERN ({n} matches in {m['file']})", flush=True)
        missed += 1
        continue
    open(target, "w").write(src.replace(m["old"], m["new"]))
    try:
        exe = os.path.join(tmp, "mutant")
        manifest = os.path.join(tree, "tests", m["suite"], "kama.json")
        b = subprocess.run([kama, "build", manifest, "--debug", "-o", exe], capture_output=True, text=True)
        if b.returncode != 0:
            print(f"{m['id']}: BUILD-FAILED\n{(b.stdout + b.stderr)[-600:]}", flush=True)
            missed += 1
            continue
        work = tempfile.mkdtemp(dir=tmp)
        os.makedirs(os.path.join(work, "home"))
        try:
            r = subprocess.run([exe], capture_output=True, text=True, timeout=900,
                               env=dict(env, PGTEST_TMP=work, PGTEST_SOCKDIR=sockets, **m.get("env", {})))
            fails = [l.strip()[5:] for l in r.stdout.splitlines() if l.strip().startswith("FAIL ")]
            # A run that ends badly with no case failed died before one could: a panic, or a signal.
            if not fails and r.returncode != 0:
                fails = ["PANICKED: " + (r.stderr.strip().splitlines() or ["exit %d" % r.returncode])[-1]]
        except subprocess.TimeoutExpired:
            fails = ["(timed out)"]
        hits = [f for f in fails if m["expect"] in f]
        if hits:
            verdict, shown = "CAUGHT", hits[0]
        elif fails and fails[0].startswith("PANICKED"):
            verdict, shown = "PANICKED", fails[0]
            missed += 1
        else:
            verdict, shown = ("FAILED-ELSEWHERE", fails[0]) if fails else ("SURVIVED", "")
            missed += 1
        print(f"{m['id']}: {verdict}" + (f" — {shown}" if shown else ""), flush=True)
    finally:
        open(target, "w").write(src)
sys.exit(1 if missed else 0)
PY
