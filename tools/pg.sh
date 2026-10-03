#!/bin/sh
# pg.sh — the PostgreSQL server the integration tests run against, in a container.
#
#   tools/pg.sh up    [--version N]     start (or reuse) postgres:N, wait until it accepts TLS logins
#   tools/pg.sh down  [--version N]     remove the container
#   tools/pg.sh env   [--version N]     print the PGTEST_* settings (also written to out/pgtest-N.env)
#   tools/pg.sh psql  [--version N] [psql args…]   psql inside the container, as the superuser
#   tools/pg.sh logs  [--version N]     the server log
#   tools/pg.sh smoke [--version N]     log in once per auth method with the container's own psql
#
# N defaults to 18. Supported: 14 15 16 17 18, plus 19 while it is in beta. Each version gets its own
# container (kama-pg-N) and host port (543N, bound to 127.0.0.1 only), so versions can run side by side.
#
# The runtime is $CONTAINER_RUNTIME, else podman, else docker. The image is the official
# docker.io/library/postgres:N — for 19, the newest beta tag until GA (`19beta4`); PGTEST_IMAGE overrides. The server is configured from tests/integration/server/ (pg_hba.conf with one
# role per auth method, TLS on) and the throwaway PKI from tools/gen-test-certs.sh.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cmd=${1:-}
[ -n "$cmd" ] && shift
VERSION=18
if [ "${1:-}" = "--version" ]; then VERSION=${2:?--version needs a value}; shift 2; fi

case "$VERSION" in
    14|15|16|17|18|19) ;;
    *) echo "pg.sh: unsupported version '$VERSION' (14–19)" >&2; exit 2 ;;
esac

if [ -n "${CONTAINER_RUNTIME:-}" ]; then RT=$CONTAINER_RUNTIME
elif command -v podman >/dev/null 2>&1; then RT=podman
elif command -v docker >/dev/null 2>&1; then RT=docker
else echo "pg.sh: neither podman nor docker found (set CONTAINER_RUNTIME)" >&2; exit 1
fi

NAME="kama-pg-$VERSION"
PORT="543$VERSION"
TAG=$VERSION
[ "$VERSION" = 19 ] && TAG=19beta4   # no bare `19` tag until GA; move this when 19.0 ships
IMAGE=${PGTEST_IMAGE:-docker.io/library/postgres:$TAG}
ENVFILE="$ROOT/out/pgtest-$VERSION.env"
SUPERPW=kp_super_pw
# kp_saslprep's password, as UTF-8 in octal: U+FF2B U+FF30, U+00AD, "sasl", U+00A0, "prep", U+FB01.
SASLPREP_PW=$(printf '\357\274\253\357\274\260\302\255sasl\302\240prep\357\254\201')

running() { [ "$("$RT" inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || true)" = "true" ]; }

write_env() {
    mkdir -p "$ROOT/out"
    cat > "$ENVFILE" <<EOF
PGTEST_VERSION=$VERSION
PGTEST_HOST=127.0.0.1
PGTEST_PORT=$PORT
PGTEST_DATABASE=kp_test
PGTEST_CERTDIR=$ROOT/out/test-certs
PGTEST_SUPERUSER=postgres
PGTEST_SUPERUSER_PASSWORD=$SUPERPW
PGTEST_SCRAM_PASSWORD=kp_scram_pw
PGTEST_PASSWORD_PASSWORD=kp_password_pw
PGTEST_MD5_PASSWORD=kp_md5_pw
PGTEST_MD5_SCRAM_PASSWORD=kp_md5_scram_pw
PGTEST_SSL_ONLY_PASSWORD=kp_ssl_only_pw
PGTEST_NOSSL_PASSWORD=kp_nossl_pw
PGTEST_CLIENT_KEY_PASSWORD=kp_client_key_pw
PGTEST_SASLPREP_PASSWORD='$SASLPREP_PW'
EOF
}

# Ready means the FINAL server answers over TCP. The image's entrypoint first runs a temporary server
# listening on the Unix socket only, so a socket-only probe would pass during initialisation.
wait_ready() {
    i=0
    while [ $i -lt 120 ]; do
        if "$RT" exec "$NAME" pg_isready -q -h 127.0.0.1 -p 5432 -U postgres 2>/dev/null; then return 0; fi
        running || { echo "pg.sh: $NAME exited during startup:" >&2; "$RT" logs "$NAME" 2>&1 | tail -30 >&2; exit 1; }
        sleep 1; i=$((i + 1))
    done
    echo "pg.sh: $NAME not ready after 120 s" >&2; "$RT" logs "$NAME" 2>&1 | tail -30 >&2; exit 1
}

case "$cmd" in
    up)
        "$ROOT/tools/gen-test-certs.sh"
        # A server keeps the certificates it was created with (they are copied into PGDATA once). After a new PKI,
        # it would serve a certificate from a CA the tests no longer have: recreate it.
        if running && ! "$RT" exec "$NAME" sh -c 'cmp -s /certs/ca.crt "$PGDATA/ca.crt"' 2>/dev/null; then
            echo "pg.sh: $NAME has an older test PKI; recreating it"
            "$RT" rm -f "$NAME" >/dev/null 2>&1 || true
        fi
        if running; then
            echo "pg.sh: $NAME already running on 127.0.0.1:$PORT"
        else
            "$RT" rm -f "$NAME" >/dev/null 2>&1 || true
            "$RT" run -d --name "$NAME" \
                -e POSTGRES_PASSWORD="$SUPERPW" \
                -p "127.0.0.1:$PORT:5432" \
                -v "$ROOT/out/test-certs:/certs:ro" \
                -v "$ROOT/tests/integration/server:/kp:ro" \
                -v "$ROOT/tests/integration/server/initdb:/docker-entrypoint-initdb.d:ro" \
                "$IMAGE" >/dev/null
            wait_ready
            echo "pg.sh: $NAME ready on 127.0.0.1:$PORT ($("$RT" exec "$NAME" postgres --version))"
        fi
        write_env
        ;;
    down)
        "$RT" rm -f "$NAME" >/dev/null 2>&1 || true
        rm -f "$ENVFILE"
        echo "pg.sh: $NAME removed"
        ;;
    env)
        write_env
        cat "$ENVFILE"
        ;;
    psql)
        exec "$RT" exec -i "$NAME" psql -v ON_ERROR_STOP=1 -U postgres -d kp_test "$@"
        ;;
    logs)
        exec "$RT" logs "$NAME"
        ;;
    smoke)
        # One login per method, from inside the container over TCP, so this checks the SERVER's
        # configuration independently of the kama client. libpq wants a client key it alone can read,
        # hence the private copy.
        "$RT" exec -i -e SASLPREP_PW="$SASLPREP_PW" "$NAME" sh -eu -s <<'EOF'
cp /certs/client.key /tmp/client.key && chmod 0600 /tmp/client.key
try() {  # try <expect ok|fail> <what> <conninfo> [password]
    if PGPASSWORD="${4:-}" psql -X -A -t -q -d "$3" -c "select 1" >/dev/null 2>/tmp/err; then got=ok; else got=fail; fi
    if [ "$got" = "$1" ]; then echo "  ok    $2"; else echo "  WRONG $2 (expected $1, got $got): $(cat /tmp/err)"; exit 1; fi
}
B="host=127.0.0.1 dbname=kp_test"
try ok   "trust"                         "$B user=kp_trust sslmode=disable"
try ok   "password (cleartext)"          "$B user=kp_password sslmode=disable" kp_password_pw
try ok   "md5"                           "$B user=kp_md5 sslmode=disable" kp_md5_pw
try ok   "md5 method, SCRAM password"    "$B user=kp_md5_scram sslmode=disable require_auth=scram-sha-256" kp_md5_scram_pw
try ok   "scram-sha-256"                 "$B user=kp_scram sslmode=disable" kp_scram_pw
try ok   "scram-sha-256, SASLprep"       "$B user=kp_saslprep sslmode=disable" "$SASLPREP_PW"
try ok   "scram-sha-256-plus (TLS)"      "$B user=kp_scram sslmode=require channel_binding=require" kp_scram_pw
try ok   "verify-full vs test CA"        "host=localhost dbname=kp_test user=kp_scram sslmode=verify-full sslrootcert=/certs/ca.crt" kp_scram_pw
try fail "verify-full vs untrusted CA"   "host=localhost dbname=kp_test user=kp_scram sslmode=verify-full sslrootcert=/certs/other-ca.crt" kp_scram_pw
try ok   "client certificate"            "$B user=kp_cert sslmode=require sslcert=/certs/client.crt sslkey=/tmp/client.key"
try ok   "ssl-only role over TLS"        "$B user=kp_ssl_only sslmode=require" kp_ssl_only_pw
try fail "ssl-only role without TLS"     "$B user=kp_ssl_only sslmode=disable" kp_ssl_only_pw
try ok   "nossl role without TLS"        "$B user=kp_nossl sslmode=disable" kp_nossl_pw
try fail "nossl role over TLS"           "$B user=kp_nossl sslmode=require" kp_nossl_pw
try fail "wrong password"                "$B user=kp_scram sslmode=disable" wrong
EOF
        echo "pg.sh: smoke OK against $NAME"
        ;;
    *)
        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
