#!/bin/sh
# gen-libpq-win-cases.sh — what libpq does on Windows, asked of a Windows libpq: the psql of EDB's binaries that
# tools/pg.sh runs natively, against that server. Into tests/integration/src/libpq_win_cases.kama, which
# windows_test.kama replays through this client on Windows:
#
#   each case's name, environment ("-" for none), connection string, and whether psql connected, or else libpq's whole
#   message. @PORT@, @TMP@, @SOCK@, @CERTDIR@ and @KEYDIR@ stand for the server's port, a scratch directory, a short one
#   for socket paths, the test PKI and the client key copies; the test makes the same files in each.
#
# The cases are the WIN32 branches of libpq that a server can show: the password file's checks, Unix-domain socket
# paths, requirepeer, keepalives and tcp_user_timeout, the private key's checks, the default host, and the words of
# a refused connect. Run it on Windows with the server up (tools/pg.sh up --version 18). The generated file is
# committed; run this again and `git diff` must be empty.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=18
case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *) echo "gen-libpq-win-cases: run this on Windows: it asks the Windows libpq of tools/pg.sh's native server" >&2; exit 2 ;;
esac
ENVFILE="$ROOT/out/pgtest-$VERSION.env"
[ -f "$ENVFILE" ] || { echo "gen-libpq-win-cases: no $ENVFILE (tools/pg.sh up --version $VERSION)" >&2; exit 1; }
set -a; . "$ENVFILE"; set +a
PSQL="$ROOT/out/pg-$VERSION/bin/psql.exe"
"$ROOT/out/pg-$VERSION/bin/pg_isready.exe" -q -h 127.0.0.1 -p "$PGTEST_PORT" || { echo "gen-libpq-win-cases: the server is not up on $PGTEST_PORT" >&2; exit 1; }

tmp=$(mktemp -d)
sock=$(mktemp -d /tmp/kpgw.XXXXXX)   # a socket path is at most 107 bytes
trap 'rm -rf "$tmp" "$sock"' EXIT
mkdir -p "$tmp/scratch/adir" "$tmp/keys/keydir"
printf '127.0.0.1:%s:kp_test:kp_scram:%s\n' "$PGTEST_PORT" "$PGTEST_SCRAM_PASSWORD" > "$tmp/scratch/pgpass_open"
chmod 0644 "$tmp/scratch/pgpass_open"
cp "$PGTEST_CERTDIR/client.key" "$tmp/keys/client-0644.key"
chmod 0644 "$tmp/keys/client-0644.key"
W_TMP=$(cygpath -m "$tmp/scratch")
W_KEYS=$(cygpath -m "$tmp/keys")
W_SOCK=$(cygpath -m "$sock")
W_CERTS=$(cygpath -m "$PGTEST_CERTDIR")

B='host=127.0.0.1 port=@PORT@ dbname=kp_test'
# name | environment | connection string
cat > "$tmp/cases" <<EOF
refused|-|host=127.0.0.1 port=1 dbname=kp_test user=kp_trust sslmode=disable
pgpass_shared|PGPASSFILE=@TMP@/pgpass_open|$B user=kp_scram sslmode=disable
pgpass_nul|PGPASSFILE=NUL|$B user=kp_scram sslmode=disable
pgpass_dev_null|PGPASSFILE=/dev/null|$B user=kp_scram sslmode=disable
pgpass_directory|PGPASSFILE=@TMP@/adir|$B user=kp_scram sslmode=disable
pgpass_missing|PGPASSFILE=@TMP@/missing|$B user=kp_scram sslmode=disable
socket_missing_directory|-|host=@SOCK@/nowhere port=@PORT@ dbname=kp_test user=kp_trust
socket_empty_directory|-|host=@SOCK@ port=@PORT@ dbname=kp_test user=kp_trust
socket_abstract|-|host=@kpg_none port=@PORT@ dbname=kp_test user=kp_trust
requirepeer_over_tcp|-|$B user=kp_trust sslmode=disable requirepeer=kp_nobody
keepalives_count_text|-|$B user=kp_trust sslmode=disable keepalives_count=abc
keepalives_zero|-|$B user=kp_trust sslmode=disable keepalives_idle=0 keepalives_interval=0
tcp_user_timeout_set|-|$B user=kp_trust sslmode=disable tcp_user_timeout=5000
tcp_user_timeout_text|-|$B user=kp_trust sslmode=disable tcp_user_timeout=many
key_shared|-|$B user=kp_cert sslmode=require sslcert=@CERTDIR@/client.crt sslkey=@KEYDIR@/client-0644.key
key_directory|-|$B user=kp_cert sslmode=require sslcert=@CERTDIR@/client.crt sslkey=@KEYDIR@/keydir
default_host|PGPORT=@PORT@|dbname=kp_test user=kp_trust sslmode=disable
EOF

fill() { printf '%s' "$1" | sed -e "s|@PORT@|$PGTEST_PORT|g" -e "s|@TMP@|$W_TMP|g" -e "s|@SOCK@|$W_SOCK|g" -e "s|@CERTDIR@|$W_CERTS|g" -e "s|@KEYDIR@|$W_KEYS|g"; }
# libpq's message with this run's paths and port put back as placeholders. The longest paths go first, since the
# scratch and key directories lie under the same temporary directory.
mask() { sed -e "s|$W_KEYS|@KEYDIR@|g" -e "s|$W_TMP|@TMP@|g" -e "s|$W_SOCK|@SOCK@|g" -e "s|$W_CERTS|@CERTDIR@|g" -e "s|port $PGTEST_PORT failed|port @PORT@ failed|g" -e "s|.s.PGSQL.$PGTEST_PORT|.s.PGSQL.@PORT@|g"; }

: > "$tmp/results"
while IFS='|' read -r name assign settings; do
    conninfo=$(fill "$settings")
    # psql gets every value as written: neither MSYS runtime may turn "/dev/null" or a path into a Windows one.
    if [ "$assign" = "-" ]; then
        out=$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' MSYS2_ENV_CONV_EXCL='*' "$PSQL" -X -w -A -t -q -d "$conninfo" -c "select 'connected'" </dev/null 2>&1 | tr -d '\r') || true
    else
        var=${assign%%=*}
        value=$(fill "${assign#*=}")
        out=$(env "$var=$value" MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' MSYS2_ENV_CONV_EXCL='*' "$PSQL" -X -w -A -t -q -d "$conninfo" -c "select 'connected'" </dev/null 2>&1 | tr -d '\r') || true
    fi
    if [ "$out" = "connected" ]; then
        printf '%s\ttrue\t\n' "$name" >> "$tmp/results"
    else
        message=$(printf '%s' "$out" | sed -e '1s/^psql: error: //' | mask | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')
        printf '%s\tfalse\t%s\n' "$name" "$message" >> "$tmp/results"
    fi
done < "$tmp/cases"

perl -e '
    use strict; use warnings;
    my ($cases, $results) = @ARGV;
    open my $c, "<", $cases or die; my @case = map { chomp; [split /\|/, $_, 3] } <$c>;
    open my $r, "<", $results or die; my @res = map { chomp; [split /\t/, $_, 3] } <$r>;
    @case == @res or die "cases and results differ in number";
    sub lit { my $s = shift; die "\${ in \"$s\"" if $s =~ /\$\{/; $s =~ s/\\(?!n)/\\\\/g; $s =~ s/"/\\"/g; $s =~ s/\t/\\t/g; return $s }
    print "// GENERATED by tools/gen-libpq-win-cases.sh from the psql of EDB\x27s PostgreSQL 18.6 for Windows, against that server.\n";
    print "// Do not edit: change the script and run it again.\n//\n";
    print "// What libpq does on Windows: each case\x27s name, environment (\"-\" for none) and connection string, whether psql\n";
    print "// connected, and else libpq\x27s whole message. \@PORT\@, \@TMP\@, \@SOCK\@, \@CERTDIR\@ and \@KEYDIR\@ stand for the server\x27s\n";
    print "// port, a scratch directory, a short one for socket paths, the test PKI and the client key copies.\n";
    print "import { std::collections::DynamicArray };\nexport { winNames, winEnvironments, winSettings, winConnects, winMessages };\n";
    my @cols = (["winNames", "string", sub { $_[0][0] }], ["winEnvironments", "string", sub { $_[0][1] }],
                ["winSettings", "string", sub { $_[0][2] }], ["winConnects", "bool", sub { $_[1][1] }],
                ["winMessages", "string", sub { $_[1][2] // "" }]);
    for my $col (@cols) {
        my ($fn, $type, $get) = @$col;
        print "\nfn DynamicArray<$type> $fn() {\n    DynamicArray<$type> v = DynamicArray.empty();\n";
        for my $i (0 .. $#case) {
            my $val = $get->($case[$i], $res[$i]);
            if ($type eq "bool") { print "    v.add(item: $val);\n"; } else { printf "    v.add(item: \"%s\");\n", lit($val); }
        }
        print "    return v;\n}\n";
    }
' "$tmp/cases" "$tmp/results" > "$ROOT/tests/integration/src/libpq_win_cases.kama"
echo "gen-libpq-win-cases: wrote tests/integration/src/libpq_win_cases.kama ($(wc -l < "$tmp/cases") cases)"
