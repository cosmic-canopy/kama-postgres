#!/bin/sh
# check-readme.sh — every ```kama block in README.md must be code from an example: a run of consecutive lines of some
# examples/*/src/*.kama, so that what a reader copies compiles (tools/test.sh builds the examples) and has run against
# every server (tools/test-integration.sh runs them). Each side's common indentation is stripped before comparing, so a
# block may quote the body of a function at the README's margin. A block that matches no example fails with its README
# line, and with the nearest run of an example and the first line that differs.
#
#   tools/check-readme.sh
#
# Hermetic: it reads files and builds nothing. To change a README block, change the example and copy the lines.
# Python is $PYTHON, else the first of python3 and python that runs (on Windows, `python3` may be the Microsoft Store's
# stub, which runs nothing).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON=${PYTHON:-}
for p in python3 python; do
    if [ -z "$PYTHON" ] && "$p" -c '' >/dev/null 2>&1; then PYTHON=$p; fi
done
[ -n "$PYTHON" ] || { echo "check-readme.sh: no python3 or python that runs (set PYTHON)" >&2; exit 2; }

"$PYTHON" -I - "$ROOT" <<'PY'
import glob, os, re, sys
root = sys.argv[1]

def dedent(lines):
    lines = [l.rstrip() for l in lines]
    width = min((len(l) - len(l.lstrip(" ")) for l in lines if l), default=0)
    return [l[width:] for l in lines]

sources = {}
for path in sorted(glob.glob(os.path.join(root, "examples", "*", "src", "*.kama"))):
    sources[os.path.relpath(path, root)] = open(path, encoding="utf-8").read().split("\n")
if not sources:
    sys.exit("check-readme.sh: no examples/*/src/*.kama to quote")

readme = open(os.path.join(root, "README.md"), encoding="utf-8").read().split("\n")
blocks = []   # (README line of the fence, the block's lines)
i = 0
while i < len(readme):
    m = re.match(r"^( *)```kama\s*$", readme[i])
    if m:
        indent, start, body = m.group(1), i + 1, []
        i += 1
        while i < len(readme) and readme[i].rstrip() != indent + "```":
            body.append(readme[i][len(indent):] if readme[i].startswith(indent) else readme[i])
            i += 1
        if i == len(readme):
            sys.exit(f"check-readme.sh: README.md:{start}: a kama block is never closed")
        blocks.append((start, body))
    i += 1
if not blocks:
    sys.exit("check-readme.sh: README.md has no kama block")

bad = 0
for start, body in blocks:
    want = dedent(body)
    n = len(want)
    found = False
    nearest = (0, None, 0)   # (lines matched, source, line in it)
    for path, lines in sources.items():
        for j in range(len(lines) - n + 1):
            got = dedent(lines[j:j + n])
            if got == want:
                found = True
                break
            same = 0
            while same < n and got[same] == want[same]:
                same += 1
            if same > nearest[0]:
                nearest = (same, path, j + 1)
        if found:
            break
    if found:
        continue
    bad += 1
    print(f"check-readme.sh: README.md:{start}: this kama block ({n} lines) is not code from any example", file=sys.stderr)
    same, path, line = nearest
    if path:
        print(f"  nearest: {path}:{line}, which differs at the block's line {same + 1}:", file=sys.stderr)
        print(f"    README:  {want[same]}", file=sys.stderr)
        print(f"    example: {dedent(sources[path][line - 1:line - 1 + n])[same]}", file=sys.stderr)
if bad:
    sys.exit(1)
print(f"check-readme.sh: OK, {len(blocks)} kama blocks, each from an example")
PY
