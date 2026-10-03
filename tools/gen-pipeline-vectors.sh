#!/bin/sh
# gen-pipeline-vectors.sh — libpq's pipeline tests as test vectors for the hermetic unit tests:
#
#   tests/unit/src/pipeline_vectors.kama   every trace of src/test/modules/libpq_pipeline/traces/ (what libpq sent and
#                                          received, as PQtrace prints it in regress mode), each client line as libpq
#                                          printed it, and each server line rebuilt into the message's bytes
#
# The traces and libpq_pipeline.c (whose call sequences tests/unit/src/pipeline_trace_test.kama ports, test by test,
# with its line numbers) are pinned to the same REL_18_STABLE commit as the other generators, every file by SHA256.
# A server line's suppressed values are filled in: an OID PQtrace prints as NNNN becomes 0 for a table and, for a
# column's type, the type its length implies (4 int4, 1 bool, 8 int8, 2 int2, 16 interval, -1 text); a field it prints as "SSSS"
# stays "SSSS". Lengths are recomputed. Nothing is typed by hand.
#
# The generated file is committed. Regenerate, and check that `git diff` is empty (no server needed):
#
#   tools/gen-pipeline-vectors.sh
set -eu

COMMIT=c45ba888d7af7b38e33832a0e240e34ca98ef866
PIPELINE_C_SHA=05bbd0c88959e762d66019dc99fecfc867e1dbeef1c73ab168873661716a023e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

fetch() {  # fetch <path in the postgres tree> <local name> <sha256>
    if [ -n "${PG_SRC_DIR:-}" ] && [ -f "$PG_SRC_DIR/$1" ]; then cp "$PG_SRC_DIR/$1" "$tmp/$2"
    else curl -fsSL -o "$tmp/$2" "https://raw.githubusercontent.com/postgres/postgres/$COMMIT/$1"; fi
    got=$(shasum -a 256 "$tmp/$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || { echo "gen-pipeline-vectors: $2 sha256 $got, want $3" >&2; exit 1; }
}

fetch src/test/modules/libpq_pipeline/libpq_pipeline.c libpq_pipeline.c "$PIPELINE_C_SHA"
while read -r name sha; do
    fetch "src/test/modules/libpq_pipeline/traces/$name.trace" "$name.trace" "$sha"
done <<'EOF'
disallowed_in_pipeline b779cd6aeaddf5e83964028496abf2050094d38060e19ad06e591fc76724a226
multi_pipelines 88fa742d1dba202ff915302ac493747988531916c321c9b60a4a7c334f947e81
nosync 793b7ffbb2200d57a6c640d652b0ab41c71d117046f3a60b1b2a89336b7c86a9
pipeline_abort c3dab26ab7469fd6fbbc966ec60e7bb460427af73ea40d64fb2119f797284cc7
pipeline_idle 59cce7f0cd25151f3caca63e868651da6dd7790c173d65c16b08e5e80786a95c
prepared 8c1749dfab4a2be0d491028502410e0da35b875847a724ff3a9f8ccf7192b2cc
simple_pipeline b359dd63118b8ea65f3351988745d9bfe150d9cb717c35817d655e1f6a2b1822
singlerow 9eb9b67fc7840e7396088bb86c917d0d4e5c297233cee706ce09c9b8b4a79ffd
transaction 3144e788a01bddb45efe355eda6dc11031a40421a203b78085396849e891b069
EOF

python3 - "$tmp" "$COMMIT" > "$ROOT/tests/unit/src/pipeline_vectors.kama" <<'PY'
import re, struct, sys

tmp, commit = sys.argv[1], sys.argv[2]
names = ["simple_pipeline", "multi_pipelines", "pipeline_abort", "pipeline_idle", "nosync", "singlerow",
         "disallowed_in_pipeline", "transaction", "prepared"]
TAGS = {"ParseComplete": b"1", "BindComplete": b"2", "CloseComplete": b"3", "NoData": b"n", "EmptyQueryResponse": b"I",
        "PortalSuspended": b"s", "ReadyForQuery": b"Z", "CommandComplete": b"C", "RowDescription": b"T", "DataRow": b"D",
        "ErrorResponse": b"E", "NoticeResponse": b"N", "ParameterDescription": b"t"}
TYPE_BY_LENGTH = {4: 23, 1: 16, 8: 20, 2: 21, 16: 1186, -1: 25}

def fail(why):
    sys.stderr.write("gen-pipeline-vectors: " + why + "\n")
    sys.exit(1)

def cstring(s):
    return s.encode("utf-8") + b"\x00"

def nchar(text, at):
    # A run PQtrace printed as '...' with \xNN for each byte that is not printable.
    if text[at] != "'":
        fail("expected ' at " + repr(text[at:at + 20]))
    out = bytearray()
    i = at + 1
    while True:
        if text.startswith("\\x", i):
            out.append(int(text[i + 2:i + 4], 16)); i += 4
        elif text[i] == "'" and (i + 1 == len(text) or text[i + 1] == " "):
            return bytes(out), i + 1
        else:
            out += text[i].encode("utf-8"); i += 1

def backend(name, fields):
    body = bytearray()
    f = fields
    if name in ("ParseComplete", "BindComplete", "CloseComplete", "NoData", "EmptyQueryResponse", "PortalSuspended"):
        pass
    elif name == "ReadyForQuery":
        body += f.strip().encode()
    elif name == "CommandComplete":
        m = re.fullmatch(r' "(.*)"', f) or fail("CommandComplete " + f)
        body += cstring(m.group(1))
    elif name == "RowDescription":
        m = re.match(r' (\d+)', f); n = int(m.group(1)); rest = f[m.end():]
        body += struct.pack(">h", n)
        for _ in range(n):
            m = re.match(r' "([^"]*)" (NNNN|-?\d+) (-?\d+) (NNNN|-?\d+) (-?\d+) (-?\d+) (-?\d+)', rest) or fail("RowDescription " + f)
            col, table, attnum, typ, typlen, typmod, fmt = m.groups()
            # PQtrace reads an Int16 as unsigned (pqTraceOutputInt16), so a length of -1 prints as 65535.
            length = int(typlen)
            if length > 32767:
                length -= 65536
            table = 0 if table == "NNNN" else int(table)
            typ = TYPE_BY_LENGTH.get(length) if typ == "NNNN" else int(typ)
            if typ is None:
                fail("no type for length " + typlen)
            body += cstring(col) + struct.pack(">IhIhih", table, int(attnum), typ, length, int(typmod), int(fmt))
            rest = rest[m.end():]
    elif name == "DataRow":
        m = re.match(r' (\d+)', f); n = int(m.group(1)); i = m.end()
        body += struct.pack(">h", n)
        for _ in range(n):
            m = re.match(r' (-?\d+)', f[i:]); length = int(m.group(1)); i += m.end()
            body += struct.pack(">i", length)
            if length >= 0:
                value, i = nchar(f, i + 1)
                if len(value) != length:
                    fail("DataRow length " + str(length) + " for " + repr(value))
                body += value
    elif name in ("ErrorResponse", "NoticeResponse"):
        for code, value in re.findall(r' (\S) "(.*?)"(?= \S "| \\x00$)', f):
            body += code.encode() + cstring(value)
        if not f.endswith(" \\x00"):
            fail(name + " without its terminator: " + f)
        body += b"\x00"
    elif name == "ParameterDescription":
        parts = f.split()
        n = int(parts[0]); body += struct.pack(">h", n)
        for p in parts[1:1 + n]:
            body += struct.pack(">I", 23 if p == "NNNN" else int(p))
    else:
        fail("no rule for backend message " + name)
    return TAGS[name] + struct.pack(">i", len(body) + 4) + bytes(body)

def literal(s):
    if "${" in s:
        fail("a line holds ${, which a kama string would interpolate: " + s)
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\t", "\\t") + '"'

out = []
out.append("// Generated by tools/gen-pipeline-vectors.sh from PostgreSQL " + commit[:12] + " (REL_18_STABLE):")
out.append("// src/test/modules/libpq_pipeline/traces/*.trace. Do not edit; regenerate.")
out.append("//")
out.append("// Each trace's lines, in order: \"F\\t…\" a message libpq sent, exactly as PQtrace printed it (regress mode, OIDs")
out.append("// as NNNN), and \"B\\t<hex>\" a message it received, its bytes rebuilt from the trace.")
out.append("import { std::collections::DynamicArray };")
out.append("export { pipelineTraceNames, pipelineTrace };")
out.append("")
out.append("fn DynamicArray<string> pipelineTraceNames() {")
out.append("    DynamicArray<string> v = DynamicArray.empty();")
for n in names:
    out.append("    v.add(item: " + literal(n) + ");")
out.append("    return v;")
out.append("}")
out.append("")
out.append("fn DynamicArray<string> pipelineTrace(const ref string name) {")
out.append("    DynamicArray<string> v = DynamicArray.empty();")
for n in names:
    out.append("    if (name.equals(other: " + literal(n) + ")) {")
    for line in open(tmp + "/" + n + ".trace", encoding="utf-8").read().splitlines():
        if not line:
            continue
        direction, length, rest = line.split("\t", 2)
        if direction == "F":
            out.append("        v.add(item: " + literal(line) + ");")
        elif direction == "B":
            msg, _, fields = rest.partition("\t")
            hexed = backend(msg, fields).hex()
            out.append("        v.add(item: " + literal("B\t" + hexed) + ");")
        else:
            fail("a line that is neither F nor B: " + line)
    out.append("    }")
out.append("    return v;")
out.append("}")
print("\n".join(out))
PY
echo "gen-pipeline-vectors: wrote tests/unit/src/pipeline_vectors.kama"
