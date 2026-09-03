defmodule MOQX.Runtime.ConnectionDriver.StreamEntry do
  @moduledoc false

  alias MOQX.Transport.Conn.Stream

  @enforce_keys [:stream, :send_open?, :receive_open?]
  defstruct [:stream, :send_open?, :receive_open?]

  @type side :: :send | :receive | :both
  @type t :: %__MODULE__{
          stream: Stream.t(),
          send_open?: boolean(),
          receive_open?: boolean()
        }

  @spec new(Stream.t()) :: t()
  def new(%Stream{info: info} = stream) do
    %__MODULE__{
      stream: stream,
      send_open?: info.send_side?,
      receive_open?: info.receive_side?
    }
  end

  @spec close(t(), side()) :: t()
  def close(%__MODULE__{} = entry, :send), do: %{entry | send_open?: false}
  def close(%__MODULE__{} = entry, :receive), do: %{entry | receive_open?: false}

  def close(%__MODULE__{} = entry, :both) do
    %{entry | send_open?: false, receive_open?: false}
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{} = entry) do
    not entry.send_open? and not entry.receive_open?
  end
end
