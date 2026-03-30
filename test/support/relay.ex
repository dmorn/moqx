defmodule MOQX.Test.Relay do
  @moduledoc """
  Manages local moq-relay processes for integration tests.
  """

  @relay_binary Path.expand("../../.moq-dev/target/release/moq-relay", __DIR__)
  @relay_config Path.expand("../../.moq-dev/dev/relay.toml", __DIR__)
  @relay_url "https://localhost:4443"
  @relay_websocket_url "http://localhost:4443/anon"
  @trusted_root_ca Path.expand("fixtures/tls/rootCA.pem", __DIR__)
  @trusted_localhost_cert Path.expand("fixtures/tls/localhost.pem", __DIR__)
  @trusted_localhost_key Path.expand("fixtures/tls/localhost-key.pem", __DIR__)

  def url, do: @relay_url
  def websocket_url, do: @relay_websocket_url
  def websocket_fallback_url(http_port \\ 4545), do: "http://localhost:#{http_port}/anon"
  def trusted_root_ca, do: @trusted_root_ca

  def available? do
    File.exists?(@relay_binary) and File.exists?(@relay_config)
  end

  def trusted_tls_available? do
    File.exists?(@trusted_root_ca) and File.exists?(@trusted_localhost_cert) and
      File.exists?(@trusted_localhost_key)
  end

  @doc """
  Starts the default relay and returns a reference to stop it later.
  Waits until the relay is accepting connections.
  """
  def start do
    ensure_available!()

    # Ensure an old local test relay is not still running.
    System.cmd("pkill", ["-f", @relay_binary])
    Process.sleep(300)

    start_from_config(@relay_config, [4443])
  end

  @doc """
  Starts an isolated relay instance with distinct QUIC and HTTP/WebSocket ports.

  This is useful for exercising WebSocket fallback: clients connect to the HTTP
  port, QUIC to that port fails, and the WebSocket fallback succeeds.
  """
  def start_isolated(quic_port, http_port) when is_integer(quic_port) and is_integer(http_port) do
    ensure_available!()
    config_path = write_generated_tls_config(quic_port, http_port)
    start_from_config(config_path, [quic_port, http_port])
  end

  @doc """
  Starts an isolated relay instance with explicit localhost certificate/key files.
  """
  def start_isolated_trusted(quic_port, http_port)
      when is_integer(quic_port) and is_integer(http_port) do
    ensure_available!()
    ensure_trusted_tls_available!()

    config_path =
      write_file_tls_config(quic_port, http_port, @trusted_localhost_cert, @trusted_localhost_key)

    start_from_config(config_path, [quic_port, http_port])
  end

  @doc "Stops a previously started relay."
  def stop(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", [to_string(os_pid)])

      nil ->
        :ok
    end

    Port.close(port)
  rescue
    _ -> :ok
  end

  defp ensure_available! do
    unless available?() do
      raise """
      moq-relay not found. Build it with:
        cd .moq-dev && cargo build --release -p moq-relay
      """
    end
  end

  defp ensure_trusted_tls_available! do
    unless trusted_tls_available?() do
      raise "missing trusted TLS fixtures under test/support/fixtures/tls"
    end
  end

  defp start_from_config(config_path, ports) do
    port =
      Port.open({:spawn_executable, @relay_binary}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: [config_path],
        cd: Path.dirname(config_path)
      ])

    wait_for_ports(ports, 5_000)
    port
  end

  defp write_generated_tls_config(quic_port, http_port) do
    write_config(
      quic_port,
      http_port,
      """
      tls.generate = [\"localhost\"]
      """
    )
  end

  defp write_file_tls_config(quic_port, http_port, cert_path, key_path) do
    write_config(
      quic_port,
      http_port,
      """
      tls.cert = [#{inspect(cert_path)}]
      tls.key = [#{inspect(key_path)}]
      """
    )
  end

  defp write_config(quic_port, http_port, tls_config) do
    path = Path.join(System.tmp_dir!(), "moqx-relay-#{quic_port}-#{http_port}.toml")

    File.write!(
      path,
      """
      [log]
      level = \"error\"

      [server]
      listen = \"[::]:#{quic_port}\"
      #{String.trim_trailing(tls_config)}

      [web.http]
      listen = \"[::]:#{http_port}\"

      [auth]
      public = \"\"

      [iroh]
      enabled = false
      secret = \"./dev/relay-iroh-secret.key\"
      """
    )

    path
  end

  defp wait_for_ports(_ports, timeout) when timeout <= 0 do
    raise "Timed out waiting for moq-relay to start"
  end

  defp wait_for_ports(ports, timeout) do
    probes =
      Enum.map_join(ports, " && ", fn port ->
        "lsof -nP -iTCP:#{port} -sTCP:LISTEN -iUDP:#{port} 2>/dev/null | grep moq-relay >/dev/null"
      end)

    case System.cmd("sh", ["-c", probes]) do
      {_, 0} ->
        Process.sleep(200)
        :ok

      _ ->
        Process.sleep(100)
        wait_for_ports(ports, timeout - 100)
    end
  end
end
