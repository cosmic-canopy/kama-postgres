#!/bin/sh
# gen-test-certs.sh — the throwaway PKI the integration tests run against, generated into out/test-certs.
#
# Nothing here is ever tracked: out/ is gitignored, so no key can reach a commit or a published tarball
# (`kama publish` refuses secret-shaped names, and the registry's check.py refuses them again). The files
# are regenerated whenever the directory is missing; `--force` regenerates them anyway.
#
#   ca.crt / ca.key              the test CA the server certificate chains to (sslrootcert for verify-*)
#   server.crt / server.key      CN=localhost, SAN localhost / 127.0.0.1 / ::1 — what the container serves
#   client.crt / client.key      CN=kp_cert, for the `cert` auth method (sslcert / sslkey)
#   other-ca.crt / other-ca.key  a CA nothing chains to: verify-ca / verify-full against it must fail
#
# Keys are written 0644, not 0600. They are test keys, and the container reads them through a bind mount
# as a different uid; the server's init script copies server.key into PGDATA and makes THAT copy 0600,
# which is what PostgreSQL checks. RSA-2048 because every TLS stack under test accepts it.
#
# OPENSSL picks the binary (default: `openssl` on the PATH — LibreSSL on macOS and OpenSSL 3 on Linux both
# work, because every extension comes from a config file rather than a version-specific flag).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIR="$ROOT/out/test-certs"
OPENSSL=${OPENSSL:-openssl}

if [ -f "$DIR/ca.crt" ] && [ "${1:-}" != "--force" ]; then
    exit 0
fi
rm -rf "$DIR"
mkdir -p "$DIR"
cd "$DIR"

cat > ca.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = kama-postgres test CA
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat > other-ca.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = kama-postgres UNTRUSTED CA
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat > server.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = localhost
[v3_leaf]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, IP:127.0.0.1, IP:::1
EOF

cat > client.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = kp_cert
[v3_leaf]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

ossl() { "$OPENSSL" "$@" 2>/dev/null || { echo "gen-test-certs: $OPENSSL $1 failed" >&2; exit 1; }; }

ossl req -new -x509 -days 3650 -nodes -newkey rsa:2048 -keyout ca.key -out ca.crt -config ca.cnf -extensions v3_ca
ossl req -new -x509 -days 3650 -nodes -newkey rsa:2048 -keyout other-ca.key -out other-ca.crt -config other-ca.cnf -extensions v3_ca

for leaf in server client; do
    ossl req -new -nodes -newkey rsa:2048 -keyout "$leaf.key" -out "$leaf.csr" -config "$leaf.cnf"
    ossl x509 -req -in "$leaf.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 \
        -out "$leaf.crt" -extfile "$leaf.cnf" -extensions v3_leaf
done

rm -f ./*.csr ./*.cnf ./*.srl
chmod 0644 ./*.key ./*.crt
echo "gen-test-certs: wrote $(ls | wc -l | tr -d ' ') files to out/test-certs"
