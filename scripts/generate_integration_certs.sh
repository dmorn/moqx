#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-.tmp/integration-certs}"
mkdir -p "$OUT_DIR"

CA_KEY="$OUT_DIR/ca.key"
CA_CERT="$OUT_DIR/ca.pem"
SERVER_KEY="$OUT_DIR/key.pem"
SERVER_CSR="$OUT_DIR/server.csr"
SERVER_CERT="$OUT_DIR/cert.pem"
SERVER_EXT="$OUT_DIR/server.ext"

openssl genrsa -out "$CA_KEY" 4096 >/dev/null 2>&1
openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
  -subj "/CN=MOQX Integration Test CA" -out "$CA_CERT" >/dev/null 2>&1

openssl genrsa -out "$SERVER_KEY" 2048 >/dev/null 2>&1
openssl req -new -key "$SERVER_KEY" -subj "/CN=localhost" -out "$SERVER_CSR" >/dev/null 2>&1

cat > "$SERVER_EXT" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$SERVER_CERT" -days 825 -sha256 -extfile "$SERVER_EXT" >/dev/null 2>&1

rm -f "$SERVER_CSR" "$SERVER_EXT" "$OUT_DIR/ca.srl"

echo "Generated integration relay certs in $OUT_DIR"
