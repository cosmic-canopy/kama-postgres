#!/bin/sh
# gen-ssl-vectors.sh — what PostgreSQL's own TLS tests expect of libpq, as test vectors for the hermetic unit tests:
#
#   tests/unit/src/ssl_name_vectors.kama   every host-name case of src/test/ssl/t/001_ssltests.pl: the server
#                                          certificate (embedded), the host asked for, and whether libpq accepts it or
#                                          the exact message it gives (sslmode=verify-full)
#   tests/unit/src/negotiate_vectors.kama  every case of src/interfaces/libpq/t/005_negotiate_encryption.pl that a
#                                          libpq without GSSAPI runs: the server's state (ssl on or off, an injection
#                                          point), the connection string, and the events the server logs (connect,
#                                          sslaccept, authfail, reconnect, …) and the outcome; and the pg_hba lines
#                                          the test writes, which the unit tests' fake server applies
#
# Upstream's tests are pinned to the same REL_18_STABLE commit as the other generators, every file by SHA256, and run
# as they are written, against stub test modules that record each connect_ok and connect_fails call with the server
# certificate in force (the last switch_server_cert). No expected value is typed by hand. Only the certificates are
# fetched, never upstream's keys: a host-name check reads a certificate's names and nothing else.
#
# The generated file is committed. Regenerate, and check that `git diff` is empty (no server needed):
#
#   tools/gen-ssl-vectors.sh
set -eu

COMMIT=c45ba888d7af7b38e33832a0e240e34ca98ef866
SSLTESTS_SHA=ccbac3f9711044d421406a8266dd423744cf5bd7b793e5c1b98e7cb36aef8bec
NEGOTIATE_SHA=a7e36afa02d5b5b2a446310ce1442f2927e47c8a244aba15fd784805e113f6d5

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

fetch() {  # fetch <path in the postgres tree> <local name> <sha256>
    if [ -n "${PG_SRC_DIR:-}" ] && [ -f "$PG_SRC_DIR/$1" ]; then cp "$PG_SRC_DIR/$1" "$tmp/$2"
    else curl -fsSL -o "$tmp/$2" "https://raw.githubusercontent.com/postgres/postgres/$COMMIT/$1"; fi
    got=$(shasum -a 256 "$tmp/$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || { echo "gen-ssl-vectors: $2 sha256 $got, want $3" >&2; exit 1; }
}

fetch src/test/ssl/t/001_ssltests.pl 001_ssltests.pl "$SSLTESTS_SHA"
fetch src/interfaces/libpq/t/005_negotiate_encryption.pl 005_negotiate_encryption.pl "$NEGOTIATE_SHA"

# The server certificates the host-name cases switch to, each pinned. A case naming any other certificate is an
# error, so a new upstream case cannot be dropped silently.
mkdir -p "$tmp/certs"
while read -r name sha; do
    fetch "src/test/ssl/ssl/$name.crt" "certs/$name.crt" "$sha"
done <<'EOF'
server-cn-only e65c21d52ab050002ca1778d3c02d82a8614f94923af67102c04a0591a79945e
server-ip-cn-only 0e066d121cad5e1c1eabb333513088e73058bc0d7402f78cdedf0d6704f6ec00
server-ip-in-dnsname 5c1ca99fa37865b8b29a69b6bc2c66b29b9c2c39343bf50d8e65c6eb964786fc
server-multiple-alt-names 55babcc640fc4aa32393aaa9934e3dbf10c55b272d043dcc9d3e0d844088d0c3
server-single-alt-name 728a45a80e4db909594794ad9ec91d6ab588b0f8da7c35be80cb529bb4ac44c8
server-ip-alt-names 40f4be2f441b0be4dbc425443e0bd8c6f4b21abadc5f51e95fd4cfea42f4e413
server-cn-and-alt-names 6fb3e6ef52a0ee165c74a83ae0c2213ef5f8786af2680c5bc779864d5a89eecf
server-cn-and-ip-alt-names 20291905750354e81e1fe9eb0b1250782a8a478c2d8024034824167324092659
server-ip-cn-and-alt-names 34057da586386db8008663b5b259ee0db885f14eba14a6a509e7a4dc5ac83ed1
server-ip-cn-and-dns-alt-names c24db5ca98be404b2f59da062ad94098a4fc5b911662fe6fe2b09fe84012bef7
server-no-names 13c35b8b47d50a439a3dfbb6feaf86acc919b6af4c26f559569ea4ddb7ea93bb
server-cn-only+server_ca 45fb918514bde10be611093f5025d3857db2ddf290f9144cfc8d5624cc1037b1
EOF

# ---- 001_ssltests.pl: run as written, against recording stubs ------------------------------------------------------
mkdir -p "$tmp/stub/PostgreSQL/Test" "$tmp/stub/Test" "$tmp/SSL"
cat > "$tmp/stub/PostgreSQL/Test/Utils.pm" <<'EOF'
package PostgreSQL::Test::Utils;
use strict; use warnings; use Exporter 'import';
our @EXPORT = qw(check_pg_config command_like $windows_os);
our $windows_os = 0;
# Every optional feature is reported present, so no case is skipped for want of one.
sub check_pg_config { return 1; }
sub command_like {}
sub tempdir { return "/tmp"; }
1;
EOF
cat > "$tmp/stub/PostgreSQL/Test/Cluster.pm" <<'EOF'
package PostgreSQL::Test::Cluster;
use strict; use warnings;
sub new { my ($class, $name) = @_; return bless { name => $name }, $class; }
sub host { return "/tmp"; } sub port { return 5432; } sub data_dir { return "/tmp/pgdata"; }
sub logfile { return "/dev/null"; } sub log_contains { return 1; }
sub safe_psql { return "OpenSSL"; }
sub init {} sub start {} sub restart {} sub append_conf {}
# One line per case: the certificate in force, whether SSL_CERT_FILE is set, the connection string, ok or fail, and
# for a failure upstream's expected stderr pattern, as written.
sub record {
    my ($outcome, $connstr, %p) = @_;
    my $expect = "";
    if ($outcome eq "fail") {
        my $re = $p{expected_stderr} // "";
        ($expect = "$re") =~ s/^\(\?\^\w*:(.*)\)$/$1/s;
    }
    my $certfile = $SSL::Server::current // "";
    my $sslcertfile = defined $ENV{SSL_CERT_FILE} ? "set" : "unset";
    print join("\t", $certfile, $sslcertfile, $connstr, $outcome, $expect), "\n";
}
sub connect_ok { my ($self, $connstr, $name, %p) = @_; record("ok", $connstr, %p); }
sub connect_fails { my ($self, $connstr, $name, %p) = @_; record("fail", $connstr, %p); }
1;
EOF
cat > "$tmp/stub/Test/More.pm" <<'EOF'
package Test::More;
use strict; use warnings; use Exporter 'import';
our @EXPORT = qw(done_testing plan ok is like note diag skip todo_skip);
sub done_testing {} sub plan {} sub ok {} sub is {} sub like {} sub note {} sub diag {}
sub skip { no warnings 'exiting'; last SKIP; }
sub todo_skip { no warnings 'exiting'; last TODO; }
1;
EOF
cat > "$tmp/SSL/Server.pm" <<'EOF'
package SSL::Server;
use strict; use warnings;
our $current;
sub new { return bless {}, shift; }
sub is_libressl { return 0; }
sub ssl_library { return "OpenSSL"; }
sub sslkey { my ($self, $name) = @_; return "ssl/$name"; }
sub configure_test_server_for_ssl {}
sub switch_server_cert { my ($self, $node, %p) = @_; $current = $p{certfile}; }
1;
EOF
with_ssl=openssl PG_TEST_EXTRA=ssl OPENSSL= perl -I"$tmp/stub" "$tmp/001_ssltests.pl" > "$tmp/ssltests.tsv"

# ---- keep the host-name cases --------------------------------------------------------------------------------------
# A case whose outcome turns on the server's names alone: verify-full (named, or the default sslrootcert=system gives)
# against a root the certificate chains to (root+server_ca.crt, or system with SSL_CERT_FILE set), with a host given.
perl -e '
    my $certs = $ARGV[0];
    my $n = 0;
    while (my $line = <STDIN>) {
        chomp $line;
        my ($cert, $sslcertfile, $connstr, $outcome, $expect) = split /\t/, $line, -1;
        my %kv;
        for my $tok (split / /, $connstr) { my ($k, $v) = split /=/, $tok, 2; $kv{$k} = $v if defined $v; }
        my $root = $kv{sslrootcert} // "";
        my $mode = $kv{sslmode} // ($root eq "system" ? "verify-full" : "prefer");
        next unless $mode eq "verify-full" && defined $kv{host};
        next unless $root eq "ssl/root+server_ca.crt" || ($root eq "system" && $sslcertfile eq "set");
        -f "$certs/$cert.crt" or die "gen-ssl-vectors: host-name case on unpinned certificate $cert\n";
        # The expected text: a pattern compiled from \Q…\E reads back quotemeta-escaped, so an escaped character is
        # itself. An unescaped "." is read as itself too (it matches the dot libpq prints, so the comparison is only
        # stricter); any other metacharacter, or an escape such as \d, means the pattern is not plain text.
        if ($outcome eq "fail") {
            my $text = "";
            my @c = split //, $expect;
            for (my $i = 0; $i < @c; $i++) {
                if ($c[$i] eq "\\") {
                    $i++;
                    die "gen-ssl-vectors: not plain text: $expect\n" if $i >= @c || $c[$i] =~ /\w/;
                    $text .= $c[$i];
                } elsif ($c[$i] =~ /[\^\$*+?()\[\]{}|]/) {
                    die "gen-ssl-vectors: not plain text: $expect\n";
                } else { $text .= $c[$i]; }
            }
            $expect = $text;
        }
        print join("\t", $cert, $kv{host}, $outcome, $expect), "\n";
        $n++;
    }
    $n >= 30 or die "gen-ssl-vectors: only $n host-name cases\n";
' "$tmp/certs" < "$tmp/ssltests.tsv" > "$tmp/names.tsv"

# ---- emit ----------------------------------------------------------------------------------------------------------
out="$ROOT/tests/unit/src/ssl_name_vectors.kama"
perl -e '
    my ($commit, $certs, $names) = @ARGV;
    sub lit { my $s = shift; die "\${ in a vector" if $s =~ /\$\{/; $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g;
              $s =~ s/\r/\\r/g; $s =~ s/\n/\\n/g; $s =~ s/\t/\\t/g; return "\"$s\""; }
    open my $h, "<", $names or die; my @rows = map { chomp; [split /\t/, $_, -1] } <$h>; close $h;
    my %seen; my @files = grep { !$seen{$_}++ } map { $_->[0] } @rows;
    print "// GENERATED by tools/gen-ssl-vectors.sh from PostgreSQL REL_18_STABLE ($commit),\n";
    print "// src/test/ssl/t/001_ssltests.pl and the server certificates it switches to (src/test/ssl/ssl/*.crt, pinned by\n";
    print "// SHA256). Do not edit: change the script and run it again.\n//\n";
    print "// Each case: a server certificate, the host libpq was asked for, and whether sslmode=verify-full accepts it\n";
    print "// (true) or fails with exactly `nameMessages()` (false).\n";
    print "import { std::collections::DynamicArray };\n";
    print "export { nameCertificates, nameHosts, nameAccepted, nameMessages, certificatePem };\n";
    for my $spec (["nameCertificates", 0, "string"], ["nameHosts", 1, "string"], ["nameAccepted", 2, "bool"], ["nameMessages", 3, "string"]) {
        my ($fn, $col, $type) = @$spec;
        print "\nfn DynamicArray<$type> $fn() {\n    DynamicArray<$type> v = DynamicArray.empty();\n";
        for my $r (@rows) {
            my $val = $r->[$col];
            if ($type eq "bool") { print "    v.add(item: " . ($val eq "ok" ? "true" : "false") . ");\n"; }
            else { print "    v.add(item: " . lit($val) . ");\n"; }
        }
        print "    return v;\n}\n";
    }
    print "\n// The PEM of each certificate the cases name.\nfn string certificatePem(const ref string name) {\n";
    for my $f (@files) {
        open my $c, "<", "$certs/$f.crt" or die; local $/; my $pem = <$c>; close $c;
        print "    if (name.equals(other: " . lit($f) . ")) { return " . lit($pem) . "; }\n";
    }
    print "    return \"\";\n}\n";
' "$COMMIT" "$tmp/certs" "$tmp/names.tsv" > "$out"
echo "gen-ssl-vectors: wrote $(wc -l < "$tmp/names.tsv" | tr -d ' ') host-name cases to tests/unit/src/ssl_name_vectors.kama"

# ---- 005_negotiate_encryption.pl: run as written, against recording stubs --------------------------------------------
# As run by a libpq built with SSL and without GSSAPI (with_ssl=openssl, with_gssapi=no), with the injection_points
# extension present. Each `is` records the server's state, the connection string connect_test built, and the
# expected events and outcome. The script writes its pg_hba.conf into the stub's data directory, which is read back.
mkdir -p "$tmp/stub5/PostgreSQL/Test" "$tmp/stub5/Test" "$tmp/data5"
: > "$tmp/data5/server.key"   # the script chmods it
cat > "$tmp/stub5/PostgreSQL/Test/Utils.pm" <<'EOF'
package PostgreSQL::Test::Utils;
use strict; use warnings; use Exporter 'import';
our @EXPORT = qw(slurp_file);
sub slurp_file { return ""; }
1;
EOF
cat > "$tmp/stub5/PostgreSQL/Test/Kerberos.pm" <<'EOF'
package PostgreSQL::Test::Kerberos;
1;
EOF
cat > "$tmp/stub5/PostgreSQL/Test/Cluster.pm" <<'EOF'
package PostgreSQL::Test::Cluster;
use strict; use warnings;
our ($ssl, $injection, $connstr) = ("off", "none", "");
sub new { return bless {}, shift; }
sub data_dir { return $ENV{STUB_DATA_DIR}; }
sub logfile { return "/dev/null"; }
sub init {} sub start {} sub reload {}
sub check_extension { return 1; }
sub append_conf { my ($self, $file, $text) = @_; $ssl = $1 if $text =~ /^ssl = (\w+)/m; }
sub adjust_conf { my ($self, $file, $name, $value) = @_; $ssl = $value if $name eq "ssl"; }
sub restart { $injection = "none"; }
sub safe_psql {
    my ($self, $db, $sql, %p) = @_;
    return "/tmp/socket-dir" if $sql =~ /unix_socket_directories/;
    $injection = $1 if $sql =~ /injection_points_attach\('([^']+)'/;
    return "";
}
sub psql { my ($self, $db, $sql, %p) = @_; $connstr = $p{connstr}; return (1, "", ""); }
1;
EOF
cat > "$tmp/stub5/Test/More.pm" <<'EOF'
package Test::More;
use strict; use warnings; use Exporter 'import';
our @EXPORT = qw(done_testing plan ok is like note diag skip);
$Test::Builder::Level = 1;
sub done_testing {} sub plan {} sub ok {} sub like {} sub note {} sub diag {}
sub skip { no warnings 'exiting'; last SKIP; }
sub is {
    my ($got, $expected, $name) = @_;
    my ($events, $outcome) = $expected =~ /^(.*) -> (\S+)$/ or die "unexpected expectation: $expected";
    print join("\t", $PostgreSQL::Test::Cluster::ssl, $PostgreSQL::Test::Cluster::injection, $PostgreSQL::Test::Cluster::connstr,
               $events, $outcome), "\n";
}
1;
EOF
STUB_DATA_DIR="$tmp/data5" PG_TEST_EXTRA=libpq_encryption with_ssl=openssl with_gssapi=no \
    perl -I"$tmp/stub5" "$tmp/005_negotiate_encryption.pl" > "$tmp/negotiate.tsv"
[ "$(wc -l < "$tmp/negotiate.tsv")" -ge 50 ] || { echo "gen-ssl-vectors: too few negotiation cases" >&2; exit 1; }
grep -Ev '^[[:space:]]*(#|$)' "$tmp/data5/pg_hba.conf" | awk '{ print $1 "\t" $3 }' > "$tmp/hba.tsv"

out="$ROOT/tests/unit/src/negotiate_vectors.kama"
perl -e '
    my ($commit, $cases, $hba) = @ARGV;
    sub lit { my $s = shift; die "\${ in a vector" if $s =~ /\$\{/; $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g; return "\"$s\""; }
    open my $h, "<", $cases or die; my @rows = map { chomp; [split /\t/, $_, -1] } <$h>; close $h;
    open my $b, "<", $hba or die; my @lines = map { chomp; [split /\t/, $_, -1] } <$b>; close $b;
    print "// GENERATED by tools/gen-ssl-vectors.sh from PostgreSQL REL_18_STABLE ($commit),\n";
    print "// src/interfaces/libpq/t/005_negotiate_encryption.pl, as a libpq with SSL and without GSSAPI runs it. Do not\n";
    print "// edit: change the script and run it again.\n//\n";
    print "// Each case: the server has ssl on or off and an injection point attached or not (\"none\"); the client connects\n";
    print "// with the connection string; the server logs the events, and the connection is plain, ssl, or fails. The\n";
    print "// pg_hba lines are the ones the test writes: a connection type and a user, each with trust.\n";
    print "import { std::collections::DynamicArray };\n";
    print "export { negotiateSsl, negotiateInjection, negotiateConninfo, negotiateEvents, negotiateOutcome, hbaTypes, hbaUsers };\n";
    for my $spec (["negotiateSsl", 0, "bool"], ["negotiateInjection", 1, "string"], ["negotiateConninfo", 2, "string"],
                  ["negotiateEvents", 3, "string"], ["negotiateOutcome", 4, "string"]) {
        my ($fn, $col, $type) = @$spec;
        print "\nfn DynamicArray<$type> $fn() {\n    DynamicArray<$type> v = DynamicArray.empty();\n";
        for my $r (@rows) {
            my $val = $r->[$col];
            if ($type eq "bool") { print "    v.add(item: " . ($val eq "on" ? "true" : "false") . ");\n"; }
            else { print "    v.add(item: " . lit($val) . ");\n"; }
        }
        print "    return v;\n}\n";
    }
    for my $spec (["hbaTypes", 0], ["hbaUsers", 1]) {
        my ($fn, $col) = @$spec;
        print "\nfn DynamicArray<string> $fn() {\n    DynamicArray<string> v = DynamicArray.empty();\n";
        print "    v.add(item: " . lit($_->[$col]) . ");\n" for @lines;
        print "    return v;\n}\n";
    }
' "$COMMIT" "$tmp/negotiate.tsv" "$tmp/hba.tsv" > "$out"
echo "gen-ssl-vectors: wrote $(wc -l < "$tmp/negotiate.tsv" | tr -d ' ') negotiation cases to tests/unit/src/negotiate_vectors.kama"
