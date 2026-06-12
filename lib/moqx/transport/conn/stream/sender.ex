defmodule MOQX.Transport.Conn.Stream.Sender do
  @moduledoc """
  Functional sender-side state for one QUIC stream.

  A sender owns the queue of accepted send tokens awaiting backend completion.
  It does not prove peer delivery; it only tracks backend credit returned by
  send-completion events.
  """

  alias MOQX.Transport.Conn.Stream

  @type t :: %__MODULE__{
          stream: Stream.t(),
          pending_sends: :queue.queue(Stream.Send.t()),
          finished_sending?: boolean()
        }

  defstruct [:stream, pending_sends: :queue.new(), finished_sending?: false]

  @doc false
  @spec new(Stream.t()) :: t()
  def new(%Stream{} = stream), do: %__MODULE__{stream: stream}

  @doc """
  Schedules bytes on this stream and returns updated sender state.
  """
  @spec send(t(), iodata(), keyword() | map()) ::
          {:ok, Stream.Send.t(), t()} | {:error, term(), t()}
  def send(%__MODULE__{} = sender, data, opts \\ []) do
    MOQX.Transport.send_stream_sender(sender, data, opts)
  end

  @doc """
  Receives one backend message for this stream sender.
  """
  @spec receive_event(t(), timeout()) ::
          {:ok, MOQX.Transport.event(), t()}
          | {:timeout, t()}
          | {:unknown, term(), t()}
          | {:error, term(), t()}
  def receive_event(%__MODULE__{} = sender, timeout \\ :infinity) do
    MOQX.Transport.receive_stream_event(sender, timeout)
  end
end
