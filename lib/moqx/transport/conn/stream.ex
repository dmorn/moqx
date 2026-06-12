defmodule MOQX.Transport.Conn.Stream do
  @moduledoc """
  Opaque QUIC stream handle returned by `MOQX.Transport`.
  """

  alias MOQX.Transport.BackendRef
  alias MOQX.Transport.Conn.Stream.Info
  alias MOQX.Transport.Conn.Stream.Sender

  @type t :: %__MODULE__{backend: BackendRef.t(), info: Info.t()}

  defstruct [:backend, :info]

  @doc """
  Creates functional sender-side state for this stream.

  The returned sender owns accepted-send correlation. It is the state value a
  caller should keep when it wants to treat stream send completions as backend
  credit.
  """
  @spec sender(t()) :: {:ok, Sender.t()} | {:error, :send_side_unavailable}
  def sender(%__MODULE__{info: %{send_side?: false}}), do: {:error, :send_side_unavailable}
  def sender(%__MODULE__{} = stream), do: {:ok, Sender.new(stream)}
end
