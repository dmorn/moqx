# TLS test fixtures

These PEM files are checked-in test fixtures for `moqx` integration tests.

They exist only to exercise the Bucket 3 client TLS paths in a hermetic way:

- `rootCA.pem` — test root CA trusted by the client via `tls: [cacertfile: ...]`
- `localhost.pem` — localhost server certificate signed by `rootCA.pem`
- `localhost-key.pem` — private key for `localhost.pem`

Scope and intent:

- local/integration testing only
- not production credentials
- not part of the public library API
- not used as a system trust store replacement

These fixtures let the test suite verify:

1. secure verification is on by default
2. explicit insecure mode still works for self-signed local dev relays
3. custom-root verification works without depending on external tools like `mkcert`

For real local development, prefer `mkcert` as described in the top-level `README.md`.
