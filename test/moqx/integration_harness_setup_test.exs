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

  test "Cloudflare relay integration is pinned and externally orchestrated in Docker and CI" do
    compose = File.read!("docker-compose.integration.yml")
    runner = File.read!("scripts/run_moq_rs_integration.sh")
    workflow = File.read!(".github/workflows/ci.yml")

    assert compose =~ "moq-rs-relay:"
    assert compose =~ "69302d3dc2422e93b8a1d62f853a6759aa9e5468"
    assert compose =~ "docker/integration/Dockerfile"
    assert runner =~ "up --build --wait moq-rs-relay"
    assert runner =~ "run --rm moqx-moq-rs-test"
    assert workflow =~ "scripts/run_moq_rs_integration.sh"
  end

  test "MoQ Lite 05 Curley integration pins the relay and CLI to one immutable source" do
    compose = File.read!("docker-compose.integration.yml")
    dockerfile = File.read!("docker/relays/curley/Dockerfile")
    runner = File.read!("scripts/run_curley_moq_lite_05_integration.sh")
    public_runner = File.read!("scripts/run_curley_moq_lite_05_public.sh")
    workflow = File.read!(".github/workflows/ci.yml")

    source_ref = "fd477082c43c3c0738fb62d077d85ea078f10045"

    assert compose =~ "curley-moq-lite-05-relay:"
    assert compose =~ source_ref
    assert dockerfile =~ "cargo build --locked --release -p moq-relay -p moq-cli"

    assert dockerfile =~
             "cargo build --locked --release -p moq-native --example moqx_curley_timestamp_probe"

    assert runner =~ "up --build --wait curley-moq-lite-05-relay"
    assert runner =~ "run --rm moqx-curley-moq-lite-05-test"
    assert compose =~ "moqx-curley-moq-lite-05-public-test:"
    assert public_runner =~ "run --rm moqx-curley-moq-lite-05-public-test"
    assert workflow =~ "scripts/run_curley_moq_lite_05_integration.sh"
  end

  test "loopback cert generator covers localhost SANs with a long validity" do
    script = File.read!("scripts/gen-loopback-certs.sh")

    assert script =~ "DNS.1 = localhost"
    assert script =~ "DNS.4 = moq-rs-relay"
    assert script =~ "IP.1 = 127.0.0.1"
    # ~100 years so routine expiry never breaks local runs (issue 55).
    assert script =~ "36500"
  end
end
