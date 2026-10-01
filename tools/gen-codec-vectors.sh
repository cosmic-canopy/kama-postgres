#!/bin/sh
# gen-codec-vectors.sh — what a real PostgreSQL says each value looks like, on the wire, into
# tests/unit/src/codec_vectors.kama. For every (type, literal) below, the server reports:
#
#   text     the type's output function under fixed settings (TimeZone UTC, DateStyle ISO, IntervalStyle
#            postgres, extra_float_digits 1), as psql receives it in a text-format column. (Not `::text`, which for
#            some types is a different cast: bool's gives "true" where the wire carries "t".)
#   binary   the type's own send function (pg_type.typsend), hex: exactly what a binary-format column carries
#
# So the unit tests decode real server bytes in both formats, re-encode them, and compare — with no server, and
# with no expected value typed by hand. The integration tests get the same file, and check each value live on every
# server version: its bytes, its text, and its kama value sent back. Both copies are committed. Regenerate them
# against a running server:
#
#   tools/pg.sh up --version 18 && tools/gen-codec-vectors.sh [--version 18]
#
# The binary formats are stable across the supported versions (14–19); the integration tests check them live on
# each.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=18
if [ "${1:-}" = "--version" ]; then VERSION=${2:?--version needs a value}; fi
OUT="$ROOT/tests/unit/src/codec_vectors.kama"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# type|literal — the literal as SQL text, cast to the type.
cat > "$tmp/cases" <<'EOF'
bool|true
bool|false
int2|0
int2|-1
int2|32767
int2|-32768
int4|0
int4|42
int4|-42
int4|2147483647
int4|-2147483648
int8|0
int8|1234567890123
int8|9223372036854775807
int8|-9223372036854775808
float4|0
float4|-0
float4|1.5
float4|-2.25
float4|3.4028235e38
float4|1e-45
float4|Infinity
float4|-Infinity
float4|NaN
float8|0
float8|-0
float8|0.1
float8|123.456
float8|-1e100
float8|1.7976931348623157e308
float8|5e-324
float8|Infinity
float8|-Infinity
float8|NaN
oid|0
oid|4294967295
text|
text|hello
text|Ünïcödé ✓ 日本語
varchar|varying
bpchar|ab
name|pg_catalog
bytea|\x
bytea|\x00ff10
bytea|hello
uuid|00000000-0000-0000-0000-000000000000
uuid|a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11
uuid|ffffffff-ffff-ffff-ffff-ffffffffffff
json|{"a": 1, "b": [true, null]}
jsonb|{"b": [true, null], "a": 1}
jsonb|"x"
date|2000-01-01
date|1999-12-31
date|1970-01-01
date|2026-09-30
date|0001-01-01
date|infinity
date|-infinity
time|00:00:00
time|12:34:56.789
time|23:59:59.999999
time|24:00:00
timetz|12:34:56+05:30
timetz|00:00:00-08
timetz|23:59:59.999999+14
timestamp|2000-01-01 00:00:00
timestamp|1970-01-01 00:00:00
timestamp|2026-09-30 12:34:56.789012
timestamp|1900-02-28 23:59:59
timestamp|infinity
timestamp|-infinity
timestamptz|2000-01-01 00:00:00+00
timestamptz|1970-01-01 00:00:00+00
timestamptz|2026-09-30 12:34:56.789012+02
timestamptz|infinity
interval|0
interval|1 year 2 months 3 days 04:05:06.789
interval|-1 day
interval|1 microsecond
interval|3 days -04:00
interval|-178000000 years
interval|1 mon -1 day 00:00:00.5
numeric|0
numeric|1
numeric|-1
numeric|0.1
numeric|123.456
numeric|-123.4560
numeric|10000
numeric|9999.9999
numeric|0.000001
numeric|1e100
numeric|12345678901234567890.12345678901234567890
numeric|1.0000
numeric|NaN
numeric|Infinity
numeric|-Infinity
int4[]|{1,2,3}
int4[]|{}
int4[]|[0:1]={5,6}
int4[]|{1,NULL,3}
int4[]|{{1,2},{3,4}}
int2[]|{-1,32767}
int8[]|{-9223372036854775808,9223372036854775807}
text[]|{a,"b c","d,e","q\"uote","back\\slash","","NULL",x}
text[]|{"{brace}", spaced , "two  spaces"}
bool[]|{t,f}
float8[]|{0.5,Infinity,NaN}
uuid[]|{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}
date[]|{2000-01-01,infinity}
timestamptz[]|{"2026-09-30 12:34:56+00"}
numeric[]|{1.5,NaN}
bytea[]|{"\\x00ff","\\x"}
jsonb[]|{"{\"a\": 1}"}
EOF

# The send function of each type (pg_type.typsend). It cannot be called through a variable in plain SQL, so it is
# named directly.
sendfn() {
    case "$1" in
        bool) echo boolsend ;; int2) echo int2send ;; int4) echo int4send ;; int8) echo int8send ;;
        float4) echo float4send ;; float8) echo float8send ;; oid) echo oidsend ;; text) echo textsend ;;
        varchar) echo varcharsend ;; bpchar) echo bpcharsend ;; name) echo namesend ;; bytea) echo byteasend ;;
        uuid) echo uuid_send ;; json) echo json_send ;; jsonb) echo jsonb_send ;; date) echo date_send ;;
        time) echo time_send ;; timetz) echo timetz_send ;; timestamp) echo timestamp_send ;;
        timestamptz) echo timestamptz_send ;; interval) echo interval_send ;; numeric) echo numeric_send ;;
        *'[]') echo array_send ;;
        *) echo "gen-codec-vectors: no send function known for $1" >&2; exit 1 ;;
    esac
}

# One query per case. Literals are passed as dollar-quoted strings so no escaping is needed.
{
    echo "SET TimeZone = 'UTC'; SET DateStyle = 'ISO, MDY'; SET IntervalStyle = 'postgres'; SET extra_float_digits = 1;"
    while IFS='|' read -r type literal; do
        fn=$(sendfn "$type")
        printf "SELECT '%s', \$lit\$%s\$lit\$, \$lit\$%s\$lit\$::%s, encode(%s(\$lit\$%s\$lit\$::%s), 'hex');\n" \
            "$type" "$literal" "$literal" "$type" "$fn" "$literal" "$type"
    done < "$tmp/cases"
} > "$tmp/query.sql"

"$ROOT/tools/pg.sh" psql --version "$VERSION" -q -A -t -F "$(printf '\t')" -f - < "$tmp/query.sql" > "$tmp/rows.tsv"
expected=$(wc -l < "$tmp/cases" | tr -d ' ')
got=$(wc -l < "$tmp/rows.tsv" | tr -d ' ')
[ "$got" = "$expected" ] || { echo "gen-codec-vectors: $got rows for $expected cases" >&2; cat "$tmp/rows.tsv" >&2; exit 1; }
server=$("$ROOT/tools/pg.sh" psql --version "$VERSION" -A -t -c 'SHOW server_version')

perl -e '
    open my $f, "<", $ARGV[0] or die;
    my @rows = map { chomp; [split /\t/, $_, -1] } <$f>;
    sub lit { my $s = shift; die "\${ in a vector" if $s =~ /\$\{/; $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g; return "\"$s\""; }
    print "// GENERATED by tools/gen-codec-vectors.sh against PostgreSQL $ARGV[1]. Do not edit: run the script again.\n";
    print "//\n// Each case: a type, the SQL literal cast to it, the text the server outputs for it (TimeZone UTC, DateStyle\n";
    print "// ISO, IntervalStyle postgres, extra_float_digits 1), and the bytes its send function produces, in hex.\n";
    print "import { std::collections::DynamicArray };\nexport { codecTypes, codecLiterals, codecTexts, codecBinaries };\n\n";
    my @cols = ([0, "codecTypes"], [1, "codecLiterals"], [2, "codecTexts"], [3, "codecBinaries"]);
    for my $c (@cols) {
        my ($i, $name) = @$c;
        print "fn DynamicArray<string> $name() {\n    DynamicArray<string> v = DynamicArray.empty();\n";
        for my $r (@rows) { print "    v.add(item: " . lit($r->[$i]) . ");\n"; }
        print "    return v;\n}\n\n";
    }
' "$tmp/rows.tsv" "$server" > "$OUT"

# The integration tests read the same vectors, on every server version.
cp "$OUT" "$ROOT/tests/integration/src/codec_vectors.kama"
echo "gen-codec-vectors: $got cases from PostgreSQL $server into $(basename "$OUT"), for the unit and integration tests"
