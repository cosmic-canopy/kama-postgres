#!/bin/sh
# gen-libpq-test-cases.sh — what libpq itself says about connection settings, as test vectors:
#
#   tests/unit/src/libpq_cases.kama          require_auth values and how libpq parses them; .pgpass lines and
#                                            service files with libpq's verdict on each
#   tests/integration/src/libpq_cases.kama   require_auth against each authentication method, and the service
#                                            file scenarios, to run against a live server
#
# Two sources, and no expected value is typed by hand:
#   - PostgreSQL's own TAP tests, pinned to the same REL_18_STABLE commit as gen-libpq-tables.sh (files pinned by
#     SHA256):
#       - src/test/authentication/t/001_password.pl gives every require_auth case, under each pg_hba method, and its
#         .pgpass file;
#       - src/interfaces/libpq/t/006_service.pl gives its service-file scenarios. It is run as it is, against stub
#         test modules that record each connect_ok and connect_fails call with the environment and files at that
#         moment.
#   - The libpq in the test server's container (tools/pg.sh), asked live:
#       - the .pgpass lines and service files below are inputs only, and libpq's answer for each is the expected
#         value;
#       - each upstream require_auth case is also run through that libpq, as the role this repo maps its pg_hba
#         method to, and must give upstream's outcome.
#
# Both generated files are committed. Regenerate, and check that `git diff` is empty, with a server up:
#
#   tools/pg.sh up --version 18 && tools/gen-libpq-test-cases.sh [--version 18]
set -eu

COMMIT=c45ba888d7af7b38e33832a0e240e34ca98ef866
PASSWORD_TEST_SHA=8f7d564f4f164d06be21ae21c03176a0f2ae30fd30ca3f4ea0aa097a55d0fff0
SERVICE_TEST_SHA=64da8d2fb83deae5c3585f8c07295a8db12e90dde3e743947fc23c3ad982d8d5

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=18
if [ "${1:-}" = "--version" ]; then VERSION=${2:?--version needs a value}; fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

if [ -n "${CONTAINER_RUNTIME:-}" ]; then RT=$CONTAINER_RUNTIME
elif command -v podman >/dev/null 2>&1; then RT=podman
else RT=docker; fi
NAME="kama-pg-$VERSION"
"$RT" exec "$NAME" true 2>/dev/null || { echo "gen-libpq-test-cases: $NAME is not running (tools/pg.sh up --version $VERSION)" >&2; exit 1; }

fetch() {  # fetch <path in the postgres tree> <local name> <sha256>
    if [ -n "${PG_SRC_DIR:-}" ] && [ -f "$PG_SRC_DIR/$2" ]; then cp "$PG_SRC_DIR/$2" "$tmp/$2"
    else curl -fsSL -o "$tmp/$2" "https://raw.githubusercontent.com/postgres/postgres/$COMMIT/$1"; fi
    got=$(shasum -a 256 "$tmp/$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || { echo "gen-libpq-test-cases: $2 sha256 $got, want $3" >&2; exit 1; }
}
fetch src/test/authentication/t/001_password.pl 001_password.pl "$PASSWORD_TEST_SHA"
fetch src/interfaces/libpq/t/006_service.pl 006_service.pl "$SERVICE_TEST_SHA"

# ---- 001_password.pl: require_auth ------------------------------------------------------------------------------
# Every connect_ok / connect_fails whose connection string sets require_auth, with the pg_hba method in force
# (the last reset_pg_hba before it). Upstream's role is always scram_role; the rest of the string is kept.
perl -e '
    my $src = do { local $/; open my $f, "<", $ARGV[0] or die; <$f> };
    my @hba;
    while ($src =~ /reset_pg_hba\(\$node,\s*\x27all\x27,\s*\x27all\x27,\s*\x27([a-z0-9-]+)\x27\)/g) { push @hba, [pos($src), $1]; }
    my $n = 0;
    while ($src =~ /\$node->(connect_ok|connect_fails)\((.*?)\);/sg) {
        my ($kind, $args, $at) = ($1, $2, pos($src));
        $args =~ /^\s*"([^"]*)"/ or next;
        my $connstr = $1;
        next unless $connstr =~ /require_auth/;
        $connstr =~ s/^user=scram_role\s*// or die "unexpected connection string: $connstr";
        my $method = "";
        for my $h (@hba) { $method = $h->[1] if $h->[0] < $at; }
        my $expect = "";
        if ($kind eq "connect_fails") {
            $args =~ /expected_stderr\s*=>\s*qr\/(.*?)\// or die "no expected_stderr for $connstr";
            $expect = $1;
            die "a regex metacharacter in \"$expect\"" if $expect =~ /[\\\[\](){}*+?|^\$]/;
        }
        printf "%s\t%s\t%s\t%s\n", $method, $connstr, ($kind eq "connect_ok" ? "ok" : "fail"), $expect;
        $n++;
    }
    $n >= 40 or die "only $n require_auth cases";
' "$tmp/001_password.pl" > "$tmp/require_auth.tsv"

# Each case through the container's libpq, as the role standing for upstream's method: it must agree.
cat > "$tmp/check_require_auth.sh" <<'EOF'
role_for() { case "$1" in trust) echo kp_trust;; password) echo kp_password;; scram-sha-256) echo kp_scram;; md5) echo kp_md5_scram;; esac; }
pw_for() { case "$1" in trust) echo "";; password) echo kp_password_pw;; scram-sha-256) echo kp_scram_pw;; md5) echo kp_md5_scram_pw;; esac; }
bad=0
err=$(mktemp)
while IFS="	" read -r method rest outcome expect; do
    role=$(role_for "$method")
    if PGPASSWORD=$(pw_for "$method") psql -X -A -t -q -d "host=127.0.0.1 dbname=kp_test sslmode=disable user=$role $rest" -c "select 1" >/dev/null 2>"$err"; then got=ok; else got=fail; fi
    if [ "$got" != "$outcome" ]; then echo "libpq disagrees: $method $rest: $got, upstream $outcome: $(cat "$err")" >&2; bad=1; fi
    if [ "$outcome" = fail ] && ! grep -qF -- "$expect" "$err"; then echo "libpq's message differs: $method $rest: $(cat "$err")" >&2; bad=1; fi
done
rm -f "$err"
exit $bad
EOF
"$RT" exec -i -u postgres "$NAME" sh -c 'cat > /tmp/check.sh' < "$tmp/check_require_auth.sh"
"$RT" exec -i -u postgres "$NAME" sh /tmp/check.sh < "$tmp/require_auth.tsv"

# ---- 001_password.pl: .pgpass -------------------------------------------------------------------------------------
# The file the test writes (two append_to_file calls after "Test .pgpass processing"), and the test_conn calls
# made with it: the role, and whether its password ('pass') was found.
perl -e '
    my $src = do { local $/; open my $f, "<", $ARGV[0] or die; <$f> };
    $src =~ /# Test \.pgpass processing(.*?)# Testing with regular expression/s or die "no .pgpass block";
    my $block = $1;
    my $file = "";
    my $n = 0;
    while ($block =~ /append_to_file\(\s*\$pgpassfile,\s*qq!(.*?)!\);|test_conn\(\$node,\s*\x27user=([a-z0-9_]+)\x27,\s*\x27password from pgpass\x27,\s*(\d)\)/sg) {
        if (defined $1) { (my $add = $1) =~ s/\\\\/\\/g; $file .= $add; next; }
        printf "%s\t%s\t%s\n", unpack("H*", $file), $2, ($3 eq "0" ? "ok" : "fail");
        $n++;
    }
    $n >= 3 or die "only $n .pgpass cases";
' "$tmp/001_password.pl" > "$tmp/pgpass_upstream.tsv"

# ---- .pgpass: libpq's verdict on each line --------------------------------------------------------------------------
# Inputs only: a file (\n separates lines, \r is a CR) and the host the client connects with. The container's libpq
# connects as kp_password, whose `password` method succeeds only with the right password: success means libpq found
# kp_password_pw for 127.0.0.1 or localhost, port 5432, database kp_test.
cat > "$tmp/pgpass_inputs" <<'EOF'
127.0.0.1|127.0.0.1:5432:kp_test:kp_password:kp_password_pw
127.0.0.1|*:*:*:*:kp_password_pw
127.0.0.1|*:*:*:*:wrong\n*:*:*:*:kp_password_pw
127.0.0.1|#127.0.0.1:5432:kp_test:kp_password:wrong\n127.0.0.1:5432:kp_test:kp_password:kp_password_pw
127.0.0.1| #127.0.0.1:5432:kp_test:kp_password:wrong\n*:*:*:*:kp_password_pw
127.0.0.1|127.0.0.1:5432:kp_test:kp_password:kp_password_pw\r\n
127.0.0.1|127.0.0.1:5432:kp\_test:kp_password:kp\_password\_pw
127.0.0.1|*.0.0.1:5432:kp_test:kp_password:kp_password_pw
127.0.0.1|127.0.0.1:5432:kp_test:kp_password:kp_password_pw:trailing text
127.0.0.1|127.0.0.1:5432:kp_test:kp_password:
127.0.0.1|127.0.0.1:5432:kp_test:kp_password
127.0.0.1|127.0.0.1:5432:kp_test:kp_password:kp_password_pw\\
127.0.0.1|127.0.0.1:*:kp_test:*:kp_password_pw
127.0.0.1|127.0.0.1:5433:kp_test:kp_password:kp_password_pw
127.0.0.1|127.0.0.1:5432:kp_test:KP_PASSWORD:kp_password_pw
127.0.0.1|127.0.0.1:5432:kp_test:kp_password:kp_password_pw\\:x
127.0.0.1|*:*:kp_test:kp_password:kp_password_pw:*:*:*
127.0.0.1|\n\n*:*:*:*:kp_password_pw\n\n
127.0.0.1|127.0.0.1\:5432:kp_test:kp_password:kp_password_pw
127.0.0.1|127.0.0.1:5432:kp_test:kp_password\:kp_password_pw
localhost|localhost:5432:kp_test:kp_password:kp_password_pw
localhost|127.0.0.1:5432:kp_test:kp_password:kp_password_pw
localhost|LOCALHOST:5432:kp_test:kp_password:kp_password_pw
EOF
python3 - "$tmp/pgpass_inputs" > "$tmp/pgpass_cases.tsv" <<'PY'
import sys
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if not line: continue
    host, content = line.split("|", 1)
    # \n and \r are line structure; \\ and \: and \_ are the file's own escapes and stay as written
    data = content.replace("\\r", "\r").replace("\\n", "\n")
    if not data.endswith("\n"): data += "\n"
    print(host + "\t" + data.encode().hex())
PY
cat > "$tmp/check_pgpass.sh" <<'EOF'
file=$(mktemp)
while IFS="	" read -r host hex; do
    printf '%s' "$hex" | perl -ne 'print pack("H*", $_)' > "$file"; chmod 0600 "$file"
    if PGPASSFILE="$file" psql -X -A -t -q -w -d "host=$host port=5432 dbname=kp_test user=kp_password sslmode=disable" -c "select 1" >/dev/null 2>&1; then got=ok; else got=fail; fi
    printf '%s\t%s\t%s\n' "$host" "$hex" "$got"
done
rm -f "$file"
EOF
"$RT" exec -i -u postgres "$NAME" sh -c 'cat > /tmp/check_pgpass.sh' < "$tmp/check_pgpass.sh"
"$RT" exec -i -u postgres "$NAME" sh /tmp/check_pgpass.sh < "$tmp/pgpass_cases.tsv" > "$tmp/pgpass_verdicts.tsv"

# ---- service files: libpq's verdict on each -----------------------------------------------------------------------
# Inputs only: a service file and the service asked for. libpq connects as the file says, over TCP to the
# container's own server, and reports `current_user|current_database()`, or its error.
cat > "$tmp/service_inputs" <<'EOF'
s|[s]\nhost=127.0.0.1\nuser=kp_trust\ndbname=kp_test
s|# a comment\n  [s]  \n  host=127.0.0.1  \n\tuser=kp_trust\ndbname=kp_test\n
s|[s] trailing words\nhost=127.0.0.1\nuser=kp_trust\ndbname=kp_test
s|[other]\nuser=kp_scram\n[s]\nhost=127.0.0.1\nuser=kp_trust\ndbname=kp_test\n[after]\nuser=kp_scram
s|[s]\nhost=127.0.0.1\nuser=kp_trust\nuser=kp_scram\ndbname=kp_test
s|[s]\nhost=127.0.0.1\nuser=kp_trust\ndbname=kp_test\nservice=other
s|[s]\nhost=127.0.0.1\nuser=kp_trust\nnot_a_keyword=1
s|[s]\nhost=127.0.0.1\nuser kp_trust
s|[s]\nhost=127.0.0.1\nuser =kp_trust
s|[ss]\nhost=127.0.0.1\nuser=kp_trust\ndbname=kp_test
s|[s\nhost=127.0.0.1\nuser=kp_trust\ndbname=kp_test
s|[s]\nhost=127.0.0.1\nuser=kp_trust\ndbname=kp_test\napplication_name=@LONG1021@
s|[s]\nhost=127.0.0.1\nuser=kp_trust\ndbname=kp_test\napplication_name=@LONG1022@
s|[s]\nhost=127.0.0.1\nuser=kp_trust\ndbname=kp_test\napplication_name=@LONG1022@@NOEOL@
s|[s]\nhost=127.0.0.1\nuser=kp_trust\ndbname=kp_test\r\n
s|[s]\r\nhost=127.0.0.1\r\nuser=kp_trust\r\ndbname=kp_test\r\n
EOF
python3 - "$tmp/service_inputs" > "$tmp/service_cases.tsv" <<'PY'
import sys
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if not line: continue
    service, content = line.split("|", 1)
    data = content.replace("\\r", "\r").replace("\\n", "\n").replace("\\t", "\t")
    # A line of exactly 1021 or 1022 bytes before its newline: "application_name=" is 17 bytes.
    data = data.replace("@LONG1021@", "a" * (1021 - 17)).replace("@LONG1022@", "a" * (1022 - 17))
    if "@NOEOL@" in data: data = data.replace("@NOEOL@", "")
    elif not data.endswith("\n"): data += "\n"
    print(service + "\t" + data.encode().hex())
PY
cat > "$tmp/check_service.sh" <<'EOF'
dir=$(mktemp -d)
while IFS="	" read -r service hex; do
    printf '%s' "$hex" | perl -ne 'print pack("H*", $_)' > "$dir/pg_service.conf"
    if out=$(PGSERVICEFILE="$dir/pg_service.conf" PGSYSCONFDIR=/nonexistent psql -X -A -t -q -w -d "service=$service sslmode=disable" -c "select current_user || '|' || current_database()" 2>"$dir/err"); then
        printf '%s\t%s\tok\t%s\n' "$service" "$hex" "$out"
    else
        printf '%s\t%s\tfail\t%s\n' "$service" "$hex" "$(sed -e 's/^psql: error: //' -e "s|$dir/|@DIR@/|g" "$dir/err" | head -1)"
    fi
done
rm -rf "$dir"
EOF
"$RT" exec -i -u postgres "$NAME" sh -c 'cat > /tmp/check_service.sh' < "$tmp/check_service.sh"
"$RT" exec -i -u postgres "$NAME" sh /tmp/check_service.sh < "$tmp/service_cases.tsv" > "$tmp/service_verdicts.tsv"

# ---- settings: libpq's verdict on each -----------------------------------------------------------------------------
# Inputs only: a connection string, and the stage libpq checks it at ("config" for pqConnectOptions2 and the integer
# settings, "connect" for what it checks host by host). libpq connects as kp_trust over TCP, and the expected value
# is "ok" or its error. sslmode, sslrootcert, sslcertmode and gssencmode values that need TLS or GSSAPI are not
# here: this libpq has them, and this client does not yet.
cat > "$tmp/settings_inputs" <<'EOF'
config|sslmode=bogus
config|channel_binding=maybe
config|connect_timeout=abc
config|connect_timeout= 5 
config|connect_timeout=5x
config|connect_timeout=-3
config|connect_timeout=99999999999
config|min_protocol_version=3.1
config|max_protocol_version=2
config|min_protocol_version=3.2 max_protocol_version=3.0
config|max_protocol_version=latest
config|min_protocol_version=latest
config|target_session_attrs=bogus
config|load_balance_hosts=bogus
config|gssencmode=bogus
config|sslnegotiation=bogus
config|ssl_min_protocol_version=TLSv9
config|ssl_max_protocol_version=tlsv1.2
config|ssl_min_protocol_version=TLSv1.3 ssl_max_protocol_version=TLSv1.2
config|ssl_min_protocol_version=TLSv1 ssl_max_protocol_version=TLSv1
config|ssl_min_protocol_version=TLSv1.1 ssl_max_protocol_version=TLSv1
config|sslcertmode=bogus
config|keepalives=x
config|keepalives=0
config|keepalives_idle=1x
config|keepalives_interval=10
config|keepalives_count=4
config|tcp_user_timeout=-5
config|tcp_user_timeout=many
config|scram_client_key=!!!
config|scram_client_key=AAAA
config|scram_server_key=AAAA
config|hostaddr=127.0.0.1,127.0.0.1 host=localhost
config|hostaddr=127.0.0.1 host=localhost,localhost
config|port=@PORT@,@PORT@,@PORT@ host=127.0.0.1,127.0.0.1
config|require_auth=password,!md5
config|require_auth=!password,md5
config|require_auth=password,password
config|require_auth=!none,!none
config|require_auth=none,none
config|require_auth=bogus
config|require_auth=,password
config|require_auth=password,
config|require_auth=!oauth
connect|port=99999
connect|port=abc
connect|port=0
connect|host=no-such-host.invalid
connect|hostaddr=999.0.0.1
EOF
cat > "$tmp/check_settings.sh" <<'EOF'
err=$(mktemp)
while IFS="|" read -r stage settings; do
    settings=$(printf '%s' "$settings" | sed -e "s/@PORT@/5432/g")
    if psql -X -A -t -q -w -d "host=127.0.0.1 port=5432 dbname=kp_test user=kp_trust sslmode=disable $settings" -c "select 1" >/dev/null 2>"$err"; then
        printf '%s\t%s\tok\t\n' "$stage" "$settings"
    else
        printf '%s\t%s\tfail\t%s\n' "$stage" "$settings" "$(sed -e 's/^psql: error: //' "$err" | head -1)"
    fi
done
rm -f "$err"
EOF
"$RT" exec -i -u postgres "$NAME" sh -c 'cat > /tmp/check_settings.sh' < "$tmp/check_settings.sh"
"$RT" exec -i -u postgres "$NAME" sh /tmp/check_settings.sh < "$tmp/settings_inputs" > "$tmp/settings_verdicts.tsv"

# ---- 006_service.pl: run as written, against recording stubs --------------------------------------------------------
mkdir -p "$tmp/stub/PostgreSQL/Test"
cat > "$tmp/stub/PostgreSQL/Test/Utils.pm" <<'EOF'
package PostgreSQL::Test::Utils;
use strict; use warnings; use Exporter 'import'; use File::Temp ();
our @EXPORT = qw(append_to_file);
sub tempdir { return File::Temp::tempdir(CLEANUP => 1); }
sub append_to_file { my ($f, $s) = @_; open my $h, '>>', $f or die "$f: $!"; print $h $s; close $h; }
1;
EOF
cat > "$tmp/stub/PostgreSQL/Test/Cluster.pm" <<'EOF'
package PostgreSQL::Test::Cluster;
use strict; use warnings;
sub new { my ($class, $name) = @_; return bless { name => $name }, $class; }
sub init {} sub start {} sub teardown_node {}
# The node's connection string, in the shape upstream's has (key=value split on spaces), naming this repo's server.
sub connstr { return "host=\@HOST\@ port=\@PORT\@ dbname=\@DATABASE\@ user=\@USER\@"; }
sub record {
    my ($outcome, $connstr, %p) = @_;
    my $file = $ENV{PGSERVICEFILE} // "";
    my $kind = !length($file) ? "unset" : !-e $file ? "missing" : -s $file ? "valid" : "empty";
    my $sys = (defined $ENV{PGSYSCONFDIR} && -e "$ENV{PGSYSCONFDIR}/pg_service.conf") ? "valid" : "none";
    my $service = defined $ENV{PGSERVICE} ? "set\t$ENV{PGSERVICE}" : "unset\t";
    my $expect = "";
    if ($outcome eq "fail") {
        my $re = $p{expected_stderr} // $p{expected_stdout} or die "no expected message for $connstr";
        ($expect = "$re") =~ s/^\(\?\^\w*:(.*)\)$/$1/;
    }
    if ($kind eq "valid" && !defined $main::validFile) { open my $h, '<', $file or die; local $/; $main::validFile = <$h>; }
    print "$kind\t$sys\t$service\t$connstr\t$outcome\t$expect\n";
}
sub connect_ok { my ($self, $connstr, $name, %p) = @_; record("ok", $connstr, %p); }
sub connect_fails { my ($self, $connstr, $name, %p) = @_; record("fail", $connstr, %p); }
END { if (defined $main::validFile) { open my $h, '>', $ENV{SERVICE_VALID_OUT} or die; print $h $main::validFile; close $h; } }
1;
EOF
mkdir -p "$tmp/stub/Test"
cat > "$tmp/stub/Test/More.pm" <<'EOF'
package Test::More;
use strict; use warnings; use Exporter 'import';
our @EXPORT = qw(done_testing plan ok is like);
sub done_testing {} sub plan {} sub ok {} sub is {} sub like {}
1;
EOF
SERVICE_VALID_OUT="$tmp/service_valid" perl -I"$tmp/stub" "$tmp/006_service.pl" > "$tmp/service_scenarios.tsv"
[ "$(wc -l < "$tmp/service_scenarios.tsv")" -ge 10 ] || { echo "gen-libpq-test-cases: too few service scenarios" >&2; exit 1; }

# ---- emit -----------------------------------------------------------------------------------------------------------
emit() {  # emit <output> <header text> — reads `name|tsv-file|columns…` specs on stdin
    perl -e '
        my ($commit, $header) = @ARGV;
        sub lit { my $s = shift; die "\${ in a vector" if $s =~ /\$\{/; $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g;
                  $s =~ s/\r/\\r/g; $s =~ s/\n/\\n/g; $s =~ s/\t/\\t/g; return "\"$s\""; }
        print "// GENERATED by tools/gen-libpq-test-cases.sh from PostgreSQL REL_18_STABLE ($commit) and the libpq in the\n";
        print "// test server\x27s container. Do not edit: change the script and run it again.\n//\n";
        print "// $_\n" for split /\n/, $header;
        my @fns;
        my @specs = map { chomp; [split /\|/] } <STDIN>;
        push @fns, $_->[0] for @specs;
        print "import { std::collections::DynamicArray };\nexport { " . join(", ", @fns) . " };\n";
        for my $s (@specs) {
            my ($name, $file, $col, $type) = @$s;
            open my $h, "<", $file or die "$file: $!";
            print "\nfn DynamicArray<$type> $name() {\n    DynamicArray<$type> v = DynamicArray.empty();\n";
            while (my $line = <$h>) {
                chomp $line;
                my @f = split /\t/, $line, -1;
                my $val = $f[$col] // "";
                if ($type eq "bool") { print "    v.add(item: " . ($val eq "ok" || $val eq "valid" || $val eq "set" ? "true" : "false") . ");\n"; }
                elsif ($col =~ /^\d+$/ && $s->[4] && $s->[4] eq "hex") { print "    v.add(item: " . lit(pack("H*", $val)) . ");\n"; }
                else { print "    v.add(item: " . lit($val) . ");\n"; }
            }
            print "    return v;\n}\n";
        }
    ' "$COMMIT" "$2" > "$1"
}

mkdir -p "$ROOT/tests/integration/src"
emit "$ROOT/tests/unit/src/libpq_cases.kama" "require_auth: each value of 001_password.pl's cases, and the parse error libpq reports for it (\"\" when it
parses; the cases that fail later fail on a live server and are in tests/integration).
.pgpass: 001_password.pl's file and its cases (the role, whether its password \"pass\" is found), then this
repo's lines with libpq's verdict (\"ok\" when libpq found kp_password_pw for the host, port 5432, kp_test).
Service files: this repo's files with libpq's verdict: \"user|database\" it connected as, or its error.
Settings: this repo's connection strings, the stage libpq checks them at, and its verdict (\"ok\", or its error).
libpq connected as kp_trust to 127.0.0.1, port 5432, kp_test, with sslmode=disable before the setting." <<EOF
requireAuthValues|$tmp/require_auth.tsv|1|string
requireAuthOutcomes|$tmp/require_auth.tsv|2|bool
requireAuthErrors|$tmp/require_auth.tsv|3|string
pgpassUpstreamFiles|$tmp/pgpass_upstream.tsv|0|string|hex
pgpassUpstreamUsers|$tmp/pgpass_upstream.tsv|1|string
pgpassUpstreamFound|$tmp/pgpass_upstream.tsv|2|bool
pgpassFiles|$tmp/pgpass_verdicts.tsv|1|string|hex
pgpassHosts|$tmp/pgpass_verdicts.tsv|0|string
pgpassFound|$tmp/pgpass_verdicts.tsv|2|bool
serviceFiles|$tmp/service_verdicts.tsv|1|string|hex
serviceNames|$tmp/service_verdicts.tsv|0|string
serviceConnected|$tmp/service_verdicts.tsv|2|bool
serviceResults|$tmp/service_verdicts.tsv|3|string
settingStages|$tmp/settings_verdicts.tsv|0|string
settingStrings|$tmp/settings_verdicts.tsv|1|string
settingAccepted|$tmp/settings_verdicts.tsv|2|bool
settingErrors|$tmp/settings_verdicts.tsv|3|string
EOF

printf 'valid\t%s\n' "$(od -An -tx1 -v "$tmp/service_valid" | tr -d ' \n')" > "$tmp/service_valid.tsv"
emit "$ROOT/tests/integration/src/libpq_cases.kama" "require_auth: every case of 001_password.pl, under the pg_hba method upstream set for it (this repo maps the
method to a role), the rest of its connection string, whether it connects, and the text libpq\x27s error contains.
Service files: each scenario of 006_service.pl, as it ran: PGSERVICEFILE (unset, valid, empty or missing), the
PGSYSCONFDIR file (valid or none), PGSERVICE (set or not, and its value), the connection string, the outcome, and
libpq\x27s message as upstream\x27s pattern (\".*\" matches anything). The valid file\x27s @HOST@, @PORT@, @DATABASE@ and
@USER@ stand for the test server.
Settings: as in tests/unit, and the ones libpq checks host by host are run here." <<EOF
requireAuthMethods|$tmp/require_auth.tsv|0|string
requireAuthSettings|$tmp/require_auth.tsv|1|string
requireAuthConnects|$tmp/require_auth.tsv|2|bool
requireAuthMessages|$tmp/require_auth.tsv|3|string
serviceFileKinds|$tmp/service_scenarios.tsv|0|string
serviceSysconf|$tmp/service_scenarios.tsv|1|bool
serviceEnvSet|$tmp/service_scenarios.tsv|2|bool
serviceEnvValues|$tmp/service_scenarios.tsv|3|string
serviceConnstrs|$tmp/service_scenarios.tsv|4|string
serviceOutcomes|$tmp/service_scenarios.tsv|5|bool
servicePatterns|$tmp/service_scenarios.tsv|6|string
serviceValidFile|$tmp/service_valid.tsv|1|string|hex
settingStages|$tmp/settings_verdicts.tsv|0|string
settingStrings|$tmp/settings_verdicts.tsv|1|string
settingAccepted|$tmp/settings_verdicts.tsv|2|bool
settingErrors|$tmp/settings_verdicts.tsv|3|string
EOF

echo "gen-libpq-test-cases: $(wc -l < "$tmp/require_auth.tsv" | tr -d ' ') require_auth cases (libpq agrees), $(wc -l < "$tmp/pgpass_upstream.tsv" | tr -d ' ')+$(wc -l < "$tmp/pgpass_verdicts.tsv" | tr -d ' ') .pgpass cases, $(wc -l < "$tmp/service_verdicts.tsv" | tr -d ' ') service files, $(wc -l < "$tmp/service_scenarios.tsv" | tr -d ' ') service scenarios, $(wc -l < "$tmp/settings_verdicts.tsv" | tr -d ' ') settings (PostgreSQL ${COMMIT%${COMMIT#????????}}, libpq $VERSION)"
