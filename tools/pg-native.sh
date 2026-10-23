# pg-native.sh — tools/pg.sh's native mode, on Windows, where there is no container runtime: EDB's binaries zip,
# unpacked into out/, and a server and its hot standby run by pg_ctl. tools/pg.sh sources this file with its settings
# (cmd, VERSION, PORT, STANDBY_PORT, ENVFILE, SUPERPW, SASLPREP_PW, write_env) and exits with its status.
#
# The commands are the container's, with the same ports, roles, configuration (tests/integration/server/, through
# initdb/00-setup.sh and 10-roles.sql) and environment file:
#   out/pg-dist/      the zip, checked against its SHA256 before use
#   out/pg-N/         its bin, lib and share (pgAdmin and the docs are not unpacked)
#   out/pgdata-N/     the primary's PGDATA, on 543N; out/pgdata-N-standby/ the standby's, on 544N
#   out/pgdata-N.log  and out/pgdata-N-standby.log, the servers' logs
#
# Only the versions in nativeDist below are supported. Paths reach the Windows programs in their mixed form
# (C:/Users/…), which they take and MSYS leaves alone.

# EDB's zip for a version, and its SHA256. EDB publishes no checksums: each hash is the one taken when the version was
# first pinned, so a changed download fails rather than runs.
nativeDist() {
    case "$1" in
        18) echo "postgresql-18.6-1-windows-x64-binaries.zip fbe23da234ee31547bf8a36d29dfd81e82b849df2d2b78d2eecb43d360252f8c" ;;
        *) echo "pg.sh: no native server for PostgreSQL $1 on this platform (only 18)" >&2; return 1 ;;
    esac
}

DIST_LINE=$(nativeDist "$VERSION") || exit 2
ZIP=${DIST_LINE% *}
ZIP_SHA=${DIST_LINE#* }
BASE="$ROOT/out/pg-$VERSION"
DATA="$ROOT/out/pgdata-$VERSION"
SDATA="$ROOT/out/pgdata-$VERSION-standby"
LOG="$DATA.log"
SLOG="$SDATA.log"
BIN="$BASE/bin"

win() { cygpath -m "$1"; }

# The binaries, downloaded once into out/pg-dist and checked every time.
fetchDist() {
    mkdir -p "$ROOT/out/pg-dist"
    zip="$ROOT/out/pg-dist/$ZIP"
    if [ ! -f "$zip" ]; then
        echo "pg.sh: downloading $ZIP"
        curl -fsSL -o "$zip.part" "https://get.enterprisedb.com/postgresql/$ZIP"
        mv "$zip.part" "$zip"
    fi
    got=$(sha256sum "$zip" | cut -d' ' -f1)
    [ "$got" = "$ZIP_SHA" ] || { echo "pg.sh: $ZIP has sha256 $got, want $ZIP_SHA" >&2; exit 1; }
    if [ ! -x "$BIN/postgres.exe" ]; then
        rm -rf "$BASE" "$BASE.unpacking"
        mkdir -p "$BASE.unpacking"
        # `**`, which crosses directories whether or not unzip was built to stop `*` at one (Git for Windows' is).
        unzip -q "$zip" 'pgsql/bin/**' 'pgsql/lib/**' 'pgsql/share/**' -d "$BASE.unpacking"
        mv "$BASE.unpacking/pgsql" "$BASE"
        rm -rf "$BASE.unpacking"
    fi
}

superpsql() { p=$1; shift; PGPASSWORD="$SUPERPW" "$BIN/psql.exe" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$p" -U postgres "$@"; }
isRunning() { [ -d "$1" ] && "$BIN/pg_ctl.exe" -D "$(win "$1")" status >/dev/null 2>&1; }

# Ready means the server answers over TCP; the standby, that it answers and is in recovery.
waitReady() {
    i=0
    while [ $i -lt 120 ]; do
        if "$BIN/pg_isready.exe" -q -h 127.0.0.1 -p "$PORT" -U postgres; then return 0; fi
        sleep 1; i=$((i + 1))
    done
    echo "pg.sh: PostgreSQL $VERSION not ready on 127.0.0.1:$PORT after 120 s" >&2; tail -30 "$LOG" >&2; exit 1
}
waitStandby() {
    i=0
    while [ $i -lt 120 ]; do
        if [ "$("$BIN/psql.exe" -X -A -t -q -h 127.0.0.1 -p "$STANDBY_PORT" -U kp_trust -d kp_test -c 'select pg_is_in_recovery()' 2>/dev/null | tr -d '\r' || true)" = "t" ]; then return 0; fi
        sleep 1; i=$((i + 1))
    done
    echo "pg.sh: the standby is not ready on 127.0.0.1:$STANDBY_PORT after 120 s" >&2; tail -30 "$SLOG" >&2; exit 1
}

# pg_ctl, with every handle away from the caller's: on Windows the server it starts (through cmd.exe) inherits pg_ctl's, and
# would hold a caller's pipe open for as long as it runs. A failure shows the end of the server logs.
pgctl() {
    if "$BIN/pg_ctl.exe" "$@" </dev/null >/dev/null 2>&1; then return 0; fi
    echo "pg.sh: pg_ctl $* failed" >&2
    for l in "$LOG" "$SLOG"; do [ -f "$l" ] && { echo "--- $l" >&2; tail -20 "$l" >&2; }; done
    exit 1
}

startPrimary() { pgctl -D "$(win "$DATA")" -l "$(win "$LOG")" -w -t 120 start; waitReady; }

# A new primary: initdb, the container's configuration (00-setup.sh, run here with the certificates and server
# directory it reads from /certs and /kp in the image), loopback only and the version's port, then the roles.
initPrimary() {
    rm -rf "$DATA" "$SDATA"
    pw="$ROOT/out/pg-$VERSION.pw"
    printf '%s\n' "$SUPERPW" > "$pw"
    # UTF8 and en-US, as the image's en_US.utf8: the tests compare the server's messages, and Windows' own default
    # would be its ANSI code page.
    "$BIN/initdb.exe" -D "$(win "$DATA")" -U postgres --pwfile="$(win "$pw")" -E UTF8 --locale=en-US \
        --auth-local=trust --auth-host=scram-sha-256 >/dev/null
    rm -f "$pw"
    PGDATA="$DATA" KP_CERTS="$ROOT/out/test-certs" KP_DIR="$ROOT/tests/integration/server" \
        sh "$ROOT/tests/integration/server/initdb/00-setup.sh"
    {
        echo "# tools/pg.sh's native mode: loopback only (binding every interface raises Windows Firewall's prompt),"
        echo "# on this version's port."
        echo "listen_addresses = '127.0.0.1,::1'"
        echo "port = $PORT"
    } >> "$DATA/postgresql.conf"
    startPrimary
    superpsql "$PORT" -d postgres -f "$(win "$ROOT/tests/integration/server/initdb/10-roles.sql")" >/dev/null
}

# The standby: a base backup of the primary (pg_basebackup -R, so it starts in recovery and streams from it), on its
# own port.
startStandby() {
    if [ ! -s "$SDATA/PG_VERSION" ]; then
        rm -rf "$SDATA"
        PGPASSWORD=kp_repl_pw "$BIN/pg_basebackup.exe" -h 127.0.0.1 -p "$PORT" -U kp_repl -D "$(win "$SDATA")" \
            -R -X stream -c fast
        echo "port = $STANDBY_PORT" >> "$SDATA/postgresql.conf"
    fi
    isRunning "$SDATA" || pgctl -D "$(win "$SDATA")" -l "$(win "$SLOG")" -w -t 120 start
    waitStandby
}

stopServer() { if isRunning "$1"; then pgctl -D "$(win "$1")" -m fast -w -t 60 stop; fi; }

case "$cmd" in
    up)
        fetchDist
        "$ROOT/tools/gen-test-certs.sh"
        # A server keeps the certificates it was made with (copied into PGDATA once): after a new PKI, make it again.
        if [ -s "$DATA/PG_VERSION" ] && ! cmp -s "$ROOT/out/test-certs/ca.crt" "$DATA/ca.crt"; then
            echo "pg.sh: PostgreSQL $VERSION has an older test PKI; making it again"
            stopServer "$SDATA"; stopServer "$DATA"; rm -rf "$DATA" "$SDATA"
        fi
        if [ ! -s "$DATA/PG_VERSION" ]; then
            initPrimary
            echo "pg.sh: PostgreSQL $VERSION ready on 127.0.0.1:$PORT ($("$BIN/postgres.exe" --version | tr -d '\r'))"
        elif isRunning "$DATA"; then
            echo "pg.sh: PostgreSQL $VERSION already running on 127.0.0.1:$PORT"
        else
            startPrimary
            echo "pg.sh: PostgreSQL $VERSION started again on 127.0.0.1:$PORT"
        fi
        startStandby
        echo "pg.sh: its standby ready on 127.0.0.1:$STANDBY_PORT"
        write_env
        ;;
    down)
        stopServer "$SDATA"; stopServer "$DATA"
        rm -rf "$DATA" "$SDATA" "$LOG" "$SLOG"
        rm -f "$ENVFILE"
        echo "pg.sh: PostgreSQL $VERSION removed"
        ;;
    stop)
        [ -s "$DATA/PG_VERSION" ] || { echo "pg.sh: PostgreSQL $VERSION does not exist (tools/pg.sh up --version $VERSION)" >&2; exit 1; }
        # A fast shutdown, as the image's SIGINT: each session is ended with FATAL 57P01, then the server exits.
        stopServer "$DATA"
        echo "pg.sh: PostgreSQL $VERSION stopped"
        ;;
    start)
        [ -s "$DATA/PG_VERSION" ] || { echo "pg.sh: PostgreSQL $VERSION does not exist (tools/pg.sh up --version $VERSION)" >&2; exit 1; }
        isRunning "$DATA" || pgctl -D "$(win "$DATA")" -l "$(win "$LOG")" -w -t 120 start
        waitReady
        echo "pg.sh: PostgreSQL $VERSION ready on 127.0.0.1:$PORT"
        ;;
    restart)
        [ -s "$DATA/PG_VERSION" ] || { echo "pg.sh: PostgreSQL $VERSION does not exist (tools/pg.sh up --version $VERSION)" >&2; exit 1; }
        pgctl -D "$(win "$DATA")" -l "$(win "$LOG")" -m fast -w -t 120 restart
        waitReady
        echo "pg.sh: PostgreSQL $VERSION restarted on 127.0.0.1:$PORT"
        ;;
    env)
        write_env
        cat "$ENVFILE"
        ;;
    psql)
        PGPASSWORD="$SUPERPW" exec "$BIN/psql.exe" -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" -U postgres -d kp_test "$@"
        ;;
    logs)
        cat "$LOG"
        ;;
    smoke)
        # One login per method with the zip's own psql, so this checks the SERVER's configuration apart from the kama
        # client. libpq on Windows checks no key's permissions, so the client key is used where it is. kp_saslprep's
        # password goes through a password file: libpq reads PGPASSWORD in the ANSI code page on Windows, which cannot
        # hold it, and a file's bytes as they are.
        C=$(win "$ROOT/out/test-certs")
        err="$ROOT/out/pg-$VERSION-smoke.err"
        try() {  # try <expect ok|fail> <what> <conninfo> [password]
            if PGPASSWORD="${4:-}" "$BIN/psql.exe" -X -A -t -q -d "$3" -c "select 1" >/dev/null 2>"$err"; then got=ok; else got=fail; fi
            if [ "$got" = "$1" ]; then echo "  ok    $2"; else echo "  WRONG $2 (expected $1, got $got): $(cat "$err")"; exit 1; fi
        }
        B="host=127.0.0.1 port=$PORT dbname=kp_test"
        L="host=localhost port=$PORT dbname=kp_test"
        try ok   "trust"                         "$B user=kp_trust sslmode=disable"
        try ok   "password (cleartext)"          "$B user=kp_password sslmode=disable" kp_password_pw
        try ok   "md5"                           "$B user=kp_md5 sslmode=disable" kp_md5_pw
        try ok   "md5 method, SCRAM password"    "$B user=kp_md5_scram sslmode=disable require_auth=scram-sha-256" kp_md5_scram_pw
        try ok   "scram-sha-256"                 "$B user=kp_scram sslmode=disable" kp_scram_pw
        passfile="$ROOT/out/pg-$VERSION-smoke.pgpass"
        printf '127.0.0.1:%s:kp_test:kp_saslprep:%s\n' "$PORT" "$SASLPREP_PW" > "$passfile"
        try ok   "scram-sha-256, SASLprep"       "$B user=kp_saslprep sslmode=disable passfile=$(win "$passfile")"
        rm -f "$passfile"
        try ok   "scram-sha-256-plus (TLS)"      "$B user=kp_scram sslmode=require channel_binding=require" kp_scram_pw
        try ok   "verify-full vs test CA"        "$L user=kp_scram sslmode=verify-full sslrootcert=$C/ca.crt" kp_scram_pw
        try fail "verify-full vs untrusted CA"   "$L user=kp_scram sslmode=verify-full sslrootcert=$C/other-ca.crt" kp_scram_pw
        try ok   "client certificate"            "$B user=kp_cert sslmode=require sslcert=$C/client.crt sslkey=$C/client.key"
        try ok   "ssl-only role over TLS"        "$B user=kp_ssl_only sslmode=require" kp_ssl_only_pw
        try fail "ssl-only role without TLS"     "$B user=kp_ssl_only sslmode=disable" kp_ssl_only_pw
        try ok   "nossl role without TLS"        "$B user=kp_nossl sslmode=disable" kp_nossl_pw
        try fail "nossl role over TLS"           "$B user=kp_nossl sslmode=require" kp_nossl_pw
        try fail "wrong password"                "$B user=kp_scram sslmode=disable" wrong
        try ok   "client certificate required"   "$B user=kp_cert sslmode=require sslcertmode=require sslcert=$C/client.crt sslkey=$C/client.key"
        try fail "client certificate not sent"   "$B user=kp_scram sslmode=require sslcertmode=require" kp_scram_pw
        S="host=127.0.0.1 port=$STANDBY_PORT dbname=kp_test user=kp_trust sslmode=disable"
        try ok   "the standby, in recovery"      "$S"
        [ "$("$BIN/psql.exe" -X -A -t -q -d "$S" -c "select pg_is_in_recovery()" | tr -d '\r')" = "t" ] \
            && echo "  ok    the standby is in hot standby" || { echo "  WRONG the standby is not in recovery"; exit 1; }
        try ok   "direct TLS negotiation"        "$B user=kp_scram sslmode=require sslnegotiation=direct" kp_scram_pw
        rm -f "$err"
        echo "pg.sh: smoke OK against PostgreSQL $VERSION (native)"
        ;;
    *)
        sed -n '2,18p' "$ROOT/tools/pg.sh" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
