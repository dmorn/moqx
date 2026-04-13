#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="${MOQX_INTEGRATION_CERT_DIR:-.tmp/integration-certs}"
RELAY_URL="${MOQX_EXTERNAL_RELAY_URL:-https://127.0.0.1:4433}"
CACERTFILE="${MOQX_RELAY_CACERTFILE:-$CERT_DIR/ca.pem}"

mkdir -p "$CERT_DIR"
if [[ ! -f "$CERT_DIR/cert.pem" || ! -f "$CERT_DIR/key.pem" || ! -f "$CACERTFILE" ]]; then
  scripts/generate_integration_certs.sh "$CERT_DIR"
fi

export MOQX_EXTERNAL_RELAY_URL="$RELAY_URL"
export MOQX_RELAY_CACERTFILE="$CACERTFILE"

docker compose -f docker-compose.integration.yml up -d relay
trap 'docker compose -f docker-compose.integration.yml down --remove-orphans' EXIT

sleep 1
mix test.integration
