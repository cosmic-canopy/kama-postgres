#!/bin/sh
# gen-reset-vectors.sh — Npgsql's session reset (what a pooled connection is sent when it is returned), as test vectors
# for the hermetic unit tests:
#
#   tests/unit/src/reset_vectors.kama   the ROLLBACK sent first when a transaction block is open; DISCARD ALL, sent when
#                                       nothing is prepared; and for each server version on either side of every gate,
#                                       the statements sent when something is (the long form), or "" where no reset is
#                                       sent at all
#
# Read from Npgsql v10.0.3 (2026-05-27), pinned by commit and by each file's SHA256:
#   src/Npgsql/Internal/NpgsqlConnector.cs    GenerateResetMessage(), and Reset(): rollback first, then the long form
#                                             when NumPrepared > 0, else DISCARD ALL; none unless SupportsDiscard
#   src/Npgsql/Internal/NpgsqlDatabaseInfo.cs the Supports* gates, each a Version.IsGreaterOrEqual(major, minor)
#   src/Npgsql/PostgresDatabaseInfo.cs        PostgreSQL's overrides of them (UNLISTEN's Redshift check, which Npgsql's
#                                             own comment says is never used, since no reset is made for Redshift)
#   src/Npgsql/PregeneratedMessages.cs        the texts of ROLLBACK and DISCARD ALL
#
# Nothing is typed by hand: a statement or gate this generator cannot read is an error, so a change upstream cannot be
# dropped silently. The generated file is committed. Regenerate, and check that `git diff` is empty (no server needed):
#
#   tools/gen-reset-vectors.sh
set -eu

TAG=v10.0.3
COMMIT=d3768398c17877b3a916c3c4d87e8e11698991fc
CONNECTOR_SHA=7a13d79578e0a0874c5842532d450d496f7d52c0f66d3fa7c1a2984a83465274
DATABASE_INFO_SHA=5483a434b61c705dbfc6bff23267b1472063864fa4a6e1c901b34b0d5d07832d
POSTGRES_INFO_SHA=5cbf08c0a67e6ae68751b573c821a7eddf8fc12a1507fe102c65537697cb8656
PREGENERATED_SHA=b60ae0c5d4fbd57ca024e5034985514448f3e9cdb528ba1904671e408062b6a3

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

fetch() {  # fetch <path in the npgsql tree> <local name> <sha256>
    curl -fsSL -o "$tmp/$2" "https://raw.githubusercontent.com/npgsql/npgsql/$COMMIT/$1"
    got=$(shasum -a 256 "$tmp/$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || { echo "gen-reset-vectors: $2 sha256 $got, want $3" >&2; exit 1; }
}

fetch src/Npgsql/Internal/NpgsqlConnector.cs NpgsqlConnector.cs "$CONNECTOR_SHA"
fetch src/Npgsql/Internal/NpgsqlDatabaseInfo.cs NpgsqlDatabaseInfo.cs "$DATABASE_INFO_SHA"
fetch src/Npgsql/PostgresDatabaseInfo.cs PostgresDatabaseInfo.cs "$POSTGRES_INFO_SHA"
fetch src/Npgsql/PregeneratedMessages.cs PregeneratedMessages.cs "$PREGENERATED_SHA"

python3 -I - "$tmp" "$TAG" "$COMMIT" > "$ROOT/tests/unit/src/reset_vectors.kama" <<'PY'
import re, sys

tmp, tag, commit = sys.argv[1], sys.argv[2], sys.argv[3]

def fail(why):
    sys.stderr.write("gen-reset-vectors: " + why + "\n")
    sys.exit(1)

def read(name):
    return open(tmp + "/" + name, encoding="utf-8-sig").read()

connector = read("NpgsqlConnector.cs")

# GenerateResetMessage(): the opening statements, then each gated Append, in order.
m = re.search(r'void GenerateResetMessage\(\)\s*\{(.*?)_resetWithoutDeallocateMessage = ', connector, re.S) \
    or fail("GenerateResetMessage() not found")
body = m.group(1)
opening = re.search(r'new StringBuilder\("([^"]*)"\)', body) or fail("GenerateResetMessage(): its opening statements")
gated = re.findall(r'if \(DatabaseInfo\.(Supports\w+)\)\s*\{\s*sb\.Append\("([^"]*)"\);', body)
appends = re.findall(r'sb\.Append\(', body)
if len(gated) != len(appends) or not gated:
    fail("GenerateResetMessage(): " + str(len(appends)) + " appends, of which " + str(len(gated)) + " are gated as expected")

# Reset(): the rollback comes first, then the long form when anything is prepared, else DISCARD ALL; and no reset is
# generated at all unless SupportsDiscard.
r = re.search(r'internal async Task Reset\(bool async\)(.*?)\n    \}\n', connector, re.S) or fail("Reset() not found")
reset = r.group(1)
for needed in ("await Rollback(async)", "PreparedStatementManager.NumPrepared > 0",
               "PrependInternalMessage(_resetWithoutDeallocateMessage!", "PrependInternalMessage(PregeneratedMessages.DiscardAll"):
    if needed not in reset:
        fail("Reset() no longer reads as this generator expects: " + needed)
if reset.index("await Rollback(async)") > reset.index("NumPrepared > 0"):
    fail("Reset(): the rollback is no longer first")
if reset.index("_resetWithoutDeallocateMessage!") > reset.index("PregeneratedMessages.DiscardAll"):
    fail("Reset(): the long form is no longer the one for NumPrepared > 0")
enabled = re.search(r'NoResetOnClose: false \} && DatabaseInfo\.(Supports\w+)\)\s*\{\s*_sendResetOnClose = true;\s*GenerateResetMessage\(\);',
                    connector) or fail("the gate on making a reset at all")
discard_gate = enabled.group(1)
rollback = re.search(r'Task Rollback\(bool async[^)]*\)\s*\{[^}]*ExecuteInternalCommand\(PregeneratedMessages\.(\w+),', connector) \
    or fail("Rollback()'s message")

# The gates: NpgsqlDatabaseInfo's, then PostgresDatabaseInfo's overrides, whose only extra condition may be Redshift's.
gates = {}
for name, major, minor in re.findall(r'public virtual bool (Supports\w+) => Version\.IsGreaterOrEqual\((\d+), (\d+)\);',
                                     read("NpgsqlDatabaseInfo.cs")):
    gates[name] = (int(major), int(minor))
for name, major, minor, rest in re.findall(r'public override bool (Supports\w+) => Version\.IsGreaterOrEqual\((\d+), (\d+)\)([^;]*);',
                                           read("PostgresDatabaseInfo.cs")):
    if rest.strip() not in ("", "&& !IsRedshift"):
        fail("PostgresDatabaseInfo." + name + " has a condition this generator does not know: " + rest.strip())
    gates[name] = (int(major), int(minor))
used = [g for g, _ in gated] + [discard_gate]
for name in used:
    if name not in gates:
        fail("no version gate found for " + name)

pregenerated = read("PregeneratedMessages.cs")
def message(field):
    found = re.search(field + r'\s*= Generate\(buf, "([^"]*)"\);', pregenerated) or fail("PregeneratedMessages." + field)
    return found.group(1)
rollback_text = message(rollback.group(1))
discard_all = message("DiscardAll")

# The versions: on either side of every gate the reset reads, then each major version this package is tested on.
def below(v):
    major, minor = v
    return (major, minor - 1, 99) if minor > 0 else (major - 1, 99, 99)
versions = set()
for v in [gates[name] for name in used]:
    versions.add(below(v))
    versions.add((v[0], v[1], 0))
versions = sorted(versions) + [(14, 0, 0), (15, 0, 0), (16, 0, 0), (17, 0, 0), (18, 4, 0), (19, 0, 0)]

def text(v):         # server_version as the server reports it
    major, minor, patch = v
    if major >= 19: return "19beta4"
    if major >= 10: return str(major) + "." + str(minor)
    return str(major) + "." + str(minor) + "." + str(patch)
def number(v):       # PQserverVersion
    major, minor, patch = v
    return major * 10000 + minor if major >= 10 else major * 10000 + minor * 100 + patch
def holds(gate, v):
    return (v[0], v[1]) >= gates[gate]
def long_form(v):
    if not holds(discard_gate, v): return ""
    return opening.group(1) + "".join(s for g, s in gated if holds(g, v))
def short_form(v):
    return discard_all if holds(discard_gate, v) else ""

def column(kind, name, values, show):
    out = ["fn DynamicArray<" + kind + "> " + name + "() {", "    DynamicArray<" + kind + "> v = DynamicArray.empty();"]
    out += ["    v.add(item: " + show(x) + ");" for x in values]
    out += ["    return v;", "}", ""]
    return out
quoted = lambda s: '"' + s + '"'

out = ["// Generated by tools/gen-reset-vectors.sh from Npgsql " + tag + " (" + commit[:12] + "): NpgsqlConnector.cs's",
       "// GenerateResetMessage() and Reset(), the gates in NpgsqlDatabaseInfo.cs and PostgresDatabaseInfo.cs, and",
       "// PregeneratedMessages.cs. Do not edit; regenerate.",
       "//",
       "// Case i: the server_version a server reports (resetServerVersion), as PQserverVersion gives it (resetVersionNumber),",
       "// and the Query text Npgsql's reset sends it when statements are prepared (resetLongForm) and when none are",
       "// (resetShortForm), \"\" where no reset is sent. A transaction block is ended first with resetRollback().",
       "import { std::collections::DynamicArray };",
       "export { resetRollback, resetDiscardAll, resetServerVersion, resetVersionNumber, resetLongForm, resetShortForm };",
       "",
       "fn string resetRollback() { return " + quoted(rollback_text) + "; }",
       "fn string resetDiscardAll() { return " + quoted(discard_all) + "; }",
       ""]
out += column("string", "resetServerVersion", versions, lambda v: quoted(text(v)))
out += column("int32", "resetVersionNumber", versions, lambda v: str(number(v)))
out += column("string", "resetLongForm", versions, lambda v: quoted(long_form(v)))
out += column("string", "resetShortForm", versions, lambda v: quoted(short_form(v)))
print("\n".join(out).rstrip("\n"))
PY
echo "gen-reset-vectors: wrote tests/unit/src/reset_vectors.kama"
