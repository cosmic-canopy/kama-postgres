#!/bin/sh
# Runs once, as the postgres user, inside the official image's first start (docker-entrypoint-initdb.d).
# The certificates arrive read-only at /certs from out/test-certs; PostgreSQL refuses a key anyone else can
# read, so the copy in PGDATA is 0600 and owned by postgres. tools/pg-native.sh runs it too, on Windows, with
# KP_CERTS and KP_DIR naming out/test-certs and tests/integration/server.
set -eu
CERTS=${KP_CERTS:-/certs}
KP=${KP_DIR:-/kp}
cp "$CERTS/server.crt" "$CERTS/server.key" "$CERTS/server-sha384.crt" "$CERTS/server-sha384.key" "$CERTS/ca.crt" "$PGDATA/"
chmod 0600 "$PGDATA/server.key" "$PGDATA/server-sha384.key"
cp "$KP/pg_hba.conf" "$PGDATA/pg_hba.conf"
cat "$KP/postgresql.conf" >> "$PGDATA/postgresql.conf"
