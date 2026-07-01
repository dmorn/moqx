defmodule MOQX.IntegrationHarnessSetupTest do
  use ExUnit.Case, async: true

  test "test config describes externally managed QUIC integration endpoints" do
    assert {:ok, integration} = Application.fetch_env(:moqx, :integration)

    ref_server = Keyword.fetch!(integration, :quic_ref_server)
    assert Keyword.fetch!(ref_server, :host) == "127.0.0.1"
    assert Keyword.fetch!(ref_server, :port) == 4433
    assert Keyword.fetch!(ref_server, :alpn) == "moqx-test"
    assert Keyword.fetch!(ref_server, :cacertfile) == ".tmp/integration-certs/ca.pem"

    local_listener = Keyword.fetch!(integration, :local_listener)
    assert Keyword.fetch!(local_listener, :host) == "127.0.0.1"
    assert Keyword.fetch!(local_listener, :certfile) == ".tmp/integration-certs/server.pem"
    assert Keyword.fetch!(local_listener, :keyfile) == ".tmp/integration-certs/server-key.pem"
    assert Keyword.fetch!(local_listener, :cacertfile) == ".tmp/integration-certs/ca.pem"
    assert Keyword.fetch!(local_listener, :alpn) == "moqx-test"

    probe_cli = Keyword.fetch!(integration, :probe_cli)
    assert Keyword.fetch!(probe_cli, :command) == "go"
    assert Keyword.fetch!(probe_cli, :args_prefix) == ["run", "./bench/quicprobe"]
  end

  test "integration tests are excluded by default" do
    assert {:integration, true} in Keyword.fetch!(ExUnit.configuration(), :exclude)
  end

  test "compose harness provisions certificates and runs the reference QUIC server" do
    compose = File.read!("docker-compose.integration.yml")

    assert compose =~ ".tmp/integration-certs"
    assert compose =~ "quic-ref-server"
    assert compose =~ "4433:4433/udp"
    assert compose =~ "healthcheck:"
    assert compose =~ "bench/quicprobe"
    # Certificate provisioning is delegated to the shared generator script.
    assert compose =~ "gen-loopback-certs.sh"
  end

  test "loopback cert generator covers localhost SANs with a long validity" do
    script = File.read!("scripts/gen-loopback-certs.sh")

    assert script =~ "DNS.1 = localhost"
    assert script =~ "IP.1 = 127.0.0.1"
    # ~100 years so routine expiry never breaks local runs (issue 55).
    assert script =~ "36500"
  end
end
