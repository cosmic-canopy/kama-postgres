#!/bin/sh
# gen-test-certs.sh — the throwaway PKI the integration tests run against, generated into out/test-certs.
#
# Nothing here is ever tracked: out/ is gitignored, so no key can reach a commit or a published tarball
# (`kama publish` refuses secret-shaped names, and the registry's check.py refuses them again). The files are
# regenerated when the directory is missing or older than GENERATION; `--force` regenerates them anyway. A server
# started before a regeneration still serves the old certificate: tools/pg.sh up notices and recreates it.
#
#   ca.crt / ca.key              the test CA the server certificate chains to (sslrootcert for verify-*)
#   server.crt / server.key      CN=localhost, SAN localhost / 127.0.0.1 / ::1 — what the container serves
#   server-sha384.crt / .key     the same names, signed with SHA-384: its tls-server-end-point hash is SHA-384
#   client.crt / client.key      CN=kp_cert, for the `cert` auth method (sslcert / sslkey)
#   client-pkcs8.key             client.key encrypted as PKCS#8 (PBES2, AES-256-CBC); client-trad.key as a
#                                traditional AES-256 PEM. Both with CLIENT_KEY_PASSWORD (PGTEST_CLIENT_KEY_PASSWORD).
#   client-other.crt / .key      CN=kp_cert again, from the untrusted CA: the server must refuse it
#   other-ca.crt / other-ca.key  a CA nothing chains to: verify-ca / verify-full against it must fail
#   empty.crl                    the CA's CRL listing nothing
#   server-revoked.crl           the CA's CRL listing server.crt: a client that loads it refuses the server
#   crldir/<hash>.r0             server-revoked.crl under the name OpenSSL's hashed-directory lookup uses
#
# Keys are written 0644, not 0600. They are test keys, and the container reads them through a bind mount
# as a different uid; the server's init script copies server.key into PGDATA and makes THAT copy 0600,
# which is what PostgreSQL checks. RSA-2048 because every TLS stack under test accepts it.
#
# Every certificate is issued with `openssl ca`, which keeps the index a CRL is made from. OPENSSL picks the binary
# (default: `openssl` on the PATH — LibreSSL on macOS and OpenSSL 3 on Linux both work, because every extension comes
# from a config file rather than a version-specific flag).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIR="$ROOT/out/test-certs"
OPENSSL=${OPENSSL:-openssl}
# Bump GENERATION when the set of files changes, so an older out/test-certs is regenerated rather than used.
GENERATION=2
CLIENT_KEY_PASSWORD='kp_client_key_pw'

if [ "$(cat "$DIR/.generation" 2>/dev/null)" = "$GENERATION" ] && [ "${1:-}" != "--force" ]; then
    exit 0
fi
rm -rf "$DIR"
mkdir -p "$DIR/work"
cd "$DIR/work"

ossl() { "$OPENSSL" "$@" >/dev/null 2>err.txt || { echo "gen-test-certs: $OPENSSL $1 failed:" >&2; cat err.txt >&2; exit 1; }; }

# ca <name> <CN>: a self-signed CA, and the `openssl ca` configuration that issues from it.
ca() {
    cat > "$1.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $2
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[ca]
default_ca = issuer
[issuer]
dir = .
database = $1-index.txt
serial = $1-serial
new_certs_dir = .
certificate = $1.crt
private_key = $1.key
default_md = sha256
policy = anything
copy_extensions = none
unique_subject = no
[anything]
commonName = supplied
[server]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, IP:127.0.0.1, IP:::1
[client]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF
    touch "$1-index.txt"
    echo 1000 > "$1-serial"
    ossl req -new -x509 -days 3650 -nodes -newkey rsa:2048 -keyout "$1.key" -out "$1.crt" -config "$1.cnf" -extensions v3_ca
}

# leaf <name> <CN> <issuing CA> <extensions> [digest]
leaf() {
    ossl genrsa -out "$1.key" 2048
    printf '[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = %s\n' "$2" > "$1.req.cnf"
    ossl req -new -key "$1.key" -out "$1.csr" -config "$1.req.cnf"
    ossl ca -batch -config "$3.cnf" -extfile "$3.cnf" -extensions "$4" -days 825 -md "${5:-sha256}" -in "$1.csr" -out "$1.pem"
    # `openssl ca` writes a text dump before the PEM block; keep only the certificate.
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$1.pem" > "../$1.crt"
    cp "$1.key" "../$1.key"
}

ca ca "kama-postgres test CA"
ca other-ca "kama-postgres UNTRUSTED CA"
leaf server        localhost ca       server
leaf server-sha384 localhost ca       server sha384
leaf client        kp_cert   ca       client
leaf client-other  kp_cert   other-ca client

ossl pkcs8 -topk8 -v2 aes-256-cbc -in client.key -out ../client-pkcs8.key -passout "pass:$CLIENT_KEY_PASSWORD"
if ! "$OPENSSL" rsa -aes256 -traditional -in client.key -out ../client-trad.key -passout "pass:$CLIENT_KEY_PASSWORD" 2>/dev/null; then
    ossl rsa -aes256 -in client.key -out ../client-trad.key -passout "pass:$CLIENT_KEY_PASSWORD"   # LibreSSL: traditional already
fi
grep -q 'Proc-Type: 4,ENCRYPTED' ../client-trad.key || { echo "gen-test-certs: client-trad.key is not a traditional encrypted PEM" >&2; exit 1; }

# The CA's CRL before and after revoking the server certificate the containers serve. Only a client that loads the
# second refuses the server.
ossl ca -batch -config ca.cnf -gencrl -crldays 3650 -out ../empty.crl
ossl ca -batch -config ca.cnf -revoke server.pem
ossl ca -batch -config ca.cnf -gencrl -crldays 3650 -out ../server-revoked.crl
mkdir -p ../crldir
cp ../server-revoked.crl "../crldir/$("$OPENSSL" crl -hash -noout -in ../server-revoked.crl).r0"

cp ca.crt ca.key other-ca.crt other-ca.key ..
cd .. && rm -rf work
chmod 0644 ./*.key ./*.crt ./*.crl crldir/*
echo "$GENERATION" > .generation
echo "gen-test-certs: wrote $(ls | wc -l | tr -d ' ') entries to out/test-certs"
