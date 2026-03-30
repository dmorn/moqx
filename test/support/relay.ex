defmodule MOQX.Test.Relay do
  @moduledoc """
  Manages a local moq-relay process for integration tests.
  """

  @relay_binary Path.expand("../../.moq-dev/target/release/moq-relay", __DIR__)
  @relay_config Path.expand("../../.moq-dev/dev/relay.toml", __DIR__)
  @relay_url "https://localhost:4443"

  def url, do: @relay_url

  def available? do
    File.exists?(@relay_binary) and File.exists?(@relay_config)
  end

  @doc """
  Starts the relay and returns a reference to stop it later.
  Waits until the relay is accepting connections.
  """
  def start do
    unless available?() do
      raise """
      moq-relay not found. Build it with:
        cd .moq-dev && cargo build --release -p moq-relay
      """
    end

    # Ensure an old local test relay is not still running.
    System.cmd("pkill", ["-f", @relay_binary])
    Process.sleep(300)

    port =
      Port.open({:spawn_executable, @relay_binary}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: [@relay_config],
        cd: Path.dirname(@relay_config)
      ])

    wait_for_port(5_000)
    port
  end

  @doc "Stops a previously started relay."
  def stop(port) when is_port(port) do
    # Get the OS pid and kill it
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", [to_string(os_pid)])

      nil ->
        :ok
    end

    # Drain any remaining messages
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp wait_for_port(timeout) when timeout <= 0 do
    raise "Timed out waiting for moq-relay to start"
  end

  defp wait_for_port(timeout) do
    case System.cmd("sh", ["-c", "lsof -nP -iTCP:4443 -sTCP:LISTEN -iUDP:4443 2>/dev/null | grep moq-relay >/dev/null"]) do
      {_, 0} ->
        Process.sleep(200)
        :ok

      _ ->
        Process.sleep(100)
        wait_for_port(timeout - 100)
    end
  end
end
