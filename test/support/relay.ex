defmodule MOQX.Test.Relay do
  @moduledoc """
  Manages local moq-relay processes for integration tests.
  """

  @relay_binary Path.expand("../../.moq-dev/target/release/moq-relay", __DIR__)
  @relay_config Path.expand("../../.moq-dev/dev/relay.toml", __DIR__)
  @relay_url "https://localhost:4443"
  @relay_websocket_url "http://localhost:4443/anon"

  def url, do: @relay_url
  def websocket_url, do: @relay_websocket_url
  def websocket_fallback_url(http_port \\ 4545), do: "http://localhost:#{http_port}/anon"

  def available? do
    File.exists?(@relay_binary) and File.exists?(@relay_config)
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
    config_path = write_isolated_config(quic_port, http_port)
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

  defp write_isolated_config(quic_port, http_port) do
    path = Path.join(System.tmp_dir!(), "moqx-relay-#{quic_port}-#{http_port}.toml")

    File.write!(
      path,
      """
      [log]
      level = \"error\"

      [server]
      listen = \"[::]:#{quic_port}\"
      tls.generate = [\"localhost\"]

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
