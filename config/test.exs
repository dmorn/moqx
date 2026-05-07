import Config

config :moqx, :integration,
  quic_ref_server: [
    host: "127.0.0.1",
    port: 4433,
    alpn: "moqx-test",
    cacertfile: ".tmp/integration-certs/ca.pem"
  ],
  local_listener: [
    host: "127.0.0.1",
    certfile: ".tmp/integration-certs/server.pem",
    keyfile: ".tmp/integration-certs/server-key.pem",
    cacertfile: ".tmp/integration-certs/ca.pem",
    alpn: "moqx-test"
  ],
  probe_cli: [
    command: "go",
    args_prefix: ["run", "./tools/quicprobe"]
  ]
