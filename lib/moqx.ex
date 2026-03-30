defmodule MOQX do
  @moduledoc """
  Elixir bindings for Media over QUIC (MOQ) via Rustler + moq-lite.
  """

  @doc """
  Connects to a MOQ relay at the given URL.

  Returns `{:ok, :ok}` immediately. The calling process will receive
  a `{:moqx_connected, session}` message on success or
  `{:error, reason}` on failure.
  """
  def connect(url) when is_binary(url) do
    MOQX.Native.connect(url)
  end
end
