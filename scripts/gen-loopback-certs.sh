#!/usr/bin/env sh
#
# Generate a long-lived self-signed CA + server certificate for LOCAL QUIC
# loopback benchmarks and the docker integration harness.
#
# This is NOT security-critical: the certificate only authenticates a QUIC
# handshake to localhost / 127.0.0.1 / ::1 (and the docker service names). It is
# deliberately valid for ~100 years so routine expiry never interrupts local
# work. Real remote targets (e.g. reform) use their own CA and are unaffected.
#
# Usage:
#   scripts/gen-loopback-certs.sh [CERT_DIR]
#
# CERT_DIR defaults to .tmp/integration-certs. Requires the `openssl` CLI on
# PATH. The script is idempotent: it reuses an existing certificate unless it is
# missing or would expire within RENEW_WITHIN_SECONDS.

set -eu

CERT_DIR="${1:-.tmp/integration-certs}"
DAYS="${CERT_DAYS:-36500}"                  # ~100 years
RENEW_WITHIN_SECONDS="${CERT_RENEW_WITHIN_SECONDS:-2592000}"  # 30 days

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

if [ -s ca.pem ] && [ -s server.pem ] && [ -s server-key.pem ] &&
  openssl x509 -checkend "$RENEW_WITHIN_SECONDS" -noout -in server.pem >/dev/null 2>&1 &&
  openssl x509 -checkhost moq-rs-relay -noout -in server.pem >/dev/null 2>&1; then
  echo "Using existing valid loopback certificates in $CERT_DIR"
  exit 0
fi

echo "Generating ${DAYS}-day loopback certificates in $CERT_DIR"

cat >openssl.cnf <<'EOF'
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
CN = localhost

[ v3_req ]
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
DNS.2 = quic-ref-server
DNS.3 = host.docker.internal
DNS.4 = moq-rs-relay
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

openssl genrsa -out ca-key.pem 2048
openssl req -x509 -new -nodes -key ca-key.pem -sha256 -days "$DAYS" \
  -subj "/CN=moqx loopback CA" -out ca.pem

openssl genrsa -out server-key.pem 2048
openssl req -new -key server-key.pem -out server.csr -config openssl.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem \
  -CAcreateserial -out server.pem -days "$DAYS" -sha256 \
  -extensions v3_req -extfile openssl.cnf

chmod 0644 ca.pem server.pem server-key.pem
echo "Wrote ca.pem, server.pem, server-key.pem (valid ${DAYS} days) to $CERT_DIR"
