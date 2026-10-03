#!/bin/sh
# Runs once, as the postgres user, inside the official image's first start (docker-entrypoint-initdb.d).
# The certificates arrive read-only at /certs from out/test-certs; PostgreSQL refuses a key anyone else can
# read, so the copy in PGDATA is 0600 and owned by postgres.
set -eu
cp /certs/server.crt /certs/server.key /certs/server-sha384.crt /certs/server-sha384.key /certs/ca.crt "$PGDATA/"
chmod 0600 "$PGDATA/server.key" "$PGDATA/server-sha384.key"
cp /kp/pg_hba.conf "$PGDATA/pg_hba.conf"
cat /kp/postgresql.conf >> "$PGDATA/postgresql.conf"
