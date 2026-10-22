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
# or PANICKED for a mutation the program must die of. An entry may add "env": {"NAME": "value", …} for its run, and
# "timeout": seconds (900 by default); a run that times out is judged by what it printed before it was stopped.
#
# Two more suites check what is not a test program:
#   "suite": "example", "example": "<name>"   examples/<name>, built in debug and run as tools/test-integration.sh runs
#                                             it in plaintext (needs --version);
#   "suite": "readme"                         tools/check-readme.sh.
# Neither prints FAIL lines: the run fails when it exits other than 0, and `expect` is part of any line it printed.
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
# (tools/pg.sh up --version N) and reads its out/pgtest-N.env. Python is $PYTHON, else the first of python3 and python
# that runs (on Windows, `python3` may be the Microsoft Store's stub, which runs nothing).
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

PYTHON=${PYTHON:-}
for p in python3 python; do
    if [ -z "$PYTHON" ] && "$p" -c '' >/dev/null 2>&1; then PYTHON=$p; fi
done
[ -n "$PYTHON" ] || { echo "mutate.sh: no python3 or python that runs (set PYTHON)" >&2; exit 2; }

"$ROOT/tools/gen-test-certs.sh" >/dev/null
# The tree without .git and any out/, untracked files included (a step's new test is not committed yet). Git Bash on
# Windows has no rsync; tar's excludes match a name at any depth, as rsync's do.
mkdir -p "$tmp/tree"
if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude .git --exclude out "$ROOT/" "$tmp/tree/"
else
    tar -C "$ROOT" --exclude .git --exclude out -cf - . | tar -C "$tmp/tree" -xf -
fi
"$KAMA" pkg install "$tmp/tree/tests/unit/kama.json" >/dev/null
[ -z "$VERSION" ] || "$KAMA" pkg install "$tmp/tree/tests/integration/kama.json" >/dev/null
envfile=""
[ -z "$VERSION" ] || envfile="$ROOT/out/pgtest-$VERSION.env"
# The restart group drives the real servers' tools/pg.sh; an entry runs it with "env": {"PGTEST_RESTART": "1"}.
PGTEST_PGSH="$ROOT/tools/pg.sh"; export PGTEST_PGSH

"$PYTHON" -I - "$tmp" "$KAMA" "$ROOT/$FILE" "$ROOT/out/test-certs" "$envfile" "$sockets" $IDS <<'PY'
import json, os, subprocess, sys, tempfile
sys.stdout.reconfigure(encoding="utf-8")
tmp, kama, path, certs, envfile, sockets = sys.argv[1:7]
only = set(sys.argv[7:])
installed = set()

# Bytes as they are: every file and every program's output is UTF-8 with LF, on every host. A native Windows Python
# would otherwise read and write in the ANSI code page, and turn LF into CRLF.
def read(p):
    with open(p, encoding="utf-8", newline="") as f:
        return f.read()
def write(p, text):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(text)
def run(argv, **kw):
    return subprocess.run(argv, capture_output=True, encoding="utf-8", errors="replace", **kw)

def printed(out):
    if isinstance(out, bytes):
        out = out.decode("utf-8", "replace")
    return out or ""
tree = os.path.join(tmp, "tree")
env = dict(os.environ, PGTEST_CERTDIR=certs)
if envfile:
    for line in read(envfile).splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = v
missed = 0
for m in json.loads(read(path)):
    if only and m["id"] not in only:
        continue
    if m["suite"] in ("integration", "example") and not envfile:
        continue
    target = os.path.join(tree, m["file"])
    src = read(target)
    n = src.count(m["old"])
    if n != 1:
        print(f"{m['id']}: BAD-PATTERN ({n} matches in {m['file']})", flush=True)
        missed += 1
        continue
    write(target, src.replace(m["old"], m["new"]))
    try:
        if m["suite"] == "readme":
            r = run(["sh", os.path.join(tree, "tools", "check-readme.sh")])
            fails = [l.strip() for l in (r.stdout + r.stderr).splitlines() if l.strip()] if r.returncode != 0 else []
        elif m["suite"] == "example":
            # Run as tools/test-integration.sh runs it in plaintext: from its directory, the server in PG* alone.
            exe = os.path.join(tmp, "mutant")
            where = os.path.join(tree, "examples", m["example"])
            manifest = os.path.join(where, "kama.json")
            if manifest not in installed:
                run([kama, "pkg", "install", manifest])
                installed.add(manifest)
            b = run([kama, "build", manifest, "--debug", "-o", exe])
            if b.returncode != 0:
                print(f"{m['id']}: BUILD-FAILED\n{(b.stdout + b.stderr)[-600:]}", flush=True)
                missed += 1
                continue
            work = tempfile.mkdtemp(dir=tmp)
            # The home is the scratch directory: HOME off Windows, APPDATA on it. Windows needs SYSTEMROOT to start
            # Winsock.
            alone = {"PATH": os.environ["PATH"], "HOME": work, "APPDATA": work, "PGHOST": env["PGTEST_HOST"],
                     "PGPORT": env["PGTEST_PORT"], "PGDATABASE": env["PGTEST_DATABASE"], "PGUSER": "kp_trust",
                     "PGSSLMODE": "disable"}
            if "SYSTEMROOT" in os.environ:
                alone["SYSTEMROOT"] = os.environ["SYSTEMROOT"]
            try:
                r = run([exe], timeout=m.get("timeout", 900), cwd=where, env=dict(alone, **m.get("env", {})))
                # Last line first: an example says what was wrong as it exits.
                fails = [l.strip() for l in (r.stdout + r.stderr).splitlines() if l.strip()][::-1] if r.returncode != 0 else []
                if r.returncode < 0:
                    fails = ["PANICKED: signal %d" % -r.returncode] + fails
            except subprocess.TimeoutExpired as e:
                fails = [l.strip() for l in (printed(e.stdout) + printed(e.stderr)).splitlines() if l.strip()] + ["(timed out)"]
        else:
            exe = os.path.join(tmp, "mutant")
            manifest = os.path.join(tree, "tests", m["suite"], "kama.json")
            b = run([kama, "build", manifest, "--debug", "-o", exe])
            if b.returncode != 0:
                print(f"{m['id']}: BUILD-FAILED\n{(b.stdout + b.stderr)[-600:]}", flush=True)
                missed += 1
                continue
            work = tempfile.mkdtemp(dir=tmp)
            os.makedirs(os.path.join(work, "home"))
            try:
                r = run([exe], timeout=m.get("timeout", 900),
                        env=dict(env, PGTEST_TMP=work, PGTEST_SOCKDIR=sockets, **m.get("env", {})))
                fails = [l.strip()[5:] for l in r.stdout.splitlines() if l.strip().startswith("FAIL ")]
                # A run that ends badly with no case failed died before one could: a panic, or a signal.
                if not fails and r.returncode != 0:
                    fails = ["PANICKED: " + (r.stderr.strip().splitlines() or ["exit %d" % r.returncode])[-1]]
            except subprocess.TimeoutExpired as e:
                # A mutant may fail its case and then hang (a deadlock it causes later): what it printed still counts.
                out = printed(e.stdout)
                fails = [l.strip()[5:] for l in out.splitlines() if l.strip().startswith("FAIL ")] + ["(timed out)"]
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
        write(target, src)
sys.exit(1 if missed else 0)
PY
