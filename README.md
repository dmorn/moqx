# moqx

`moqx` is an Elixir Media over QUIC library.

It provides a QUIC transport boundary backed by [`quicer`](https://github.com/dmorn/quic) for building MOQT implementations in Elixir. The transport boundary keeps protocol code independent from the concrete QUIC backend and allows tests to use deterministic support transports.

## Protocol documents

`moqx` currently targets MOQT draft-14 and is expected to grow support for MOQ Lite.

Core references:

- [RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 — Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001)
- [RFC 9002 — QUIC Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002)
- [RFC 9114 — HTTP/3](https://www.rfc-editor.org/rfc/rfc9114)
- [RFC 9221 — QUIC DATAGRAM](https://www.rfc-editor.org/rfc/rfc9221)
- [RFC 9297 — HTTP Datagrams and the Capsule Protocol](https://www.rfc-editor.org/rfc/rfc9297)
- [draft-ietf-webtrans-http3-14 — WebTransport over HTTP/3](https://www.ietf.org/archive/id/draft-ietf-webtrans-http3-14.txt)
- [draft-ietf-moq-transport-14 — Media over QUIC Transport](https://www.ietf.org/archive/id/draft-ietf-moq-transport-14.txt)
- [draft-lcurley-moq-lite — MOQ Lite](https://datatracker.ietf.org/doc/draft-lcurley-moq-lite/)

## Installation

```elixir
# mix.exs
{:moqx, "~> 0.7.1"}
```

## Development

```bash
mix deps.get
mix test
mix ci
```

Default tests are fast and hermetic. Real QUIC checks are tagged as ExUnit
integration tests and are excluded by default.

To run the caller-managed QUIC integration harness:

```bash
docker compose -f docker-compose.integration.yml up -d --wait
mix test --only integration
```

ExUnit does not start Docker. Stop the harness when finished:

```bash
docker compose -f docker-compose.integration.yml down
```

The harness provisions self-signed certificates under
`.tmp/integration-certs/` and runs the repo-owned reference QUIC server from
`tools/quicprobe` on UDP port 4433.

For manual debugging, run the reference CLI directly:

```bash
go run ./tools/quicprobe server --addr :4433 \
  --cert .tmp/integration-certs/server.pem \
  --key .tmp/integration-certs/server-key.pem \
  --alpn moqx-test

go run ./tools/quicprobe client --addr 127.0.0.1:4433 \
  --ca .tmp/integration-certs/ca.pem \
  --alpn moqx-test \
  --bidi-echo hello
```

## License

MIT
