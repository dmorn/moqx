defmodule MOQX.Transport do
  @moduledoc """
  Minimal QUIC transport boundary for MOQT-family implementations.

  The protocol layer should depend on this behaviour rather than on a concrete
  QUIC library. Tests can provide an in-memory implementation with the same
  connection, stream, datagram, and event semantics.

  Stream data is ordered within a stream. The transport contract does not
  promise ordering across different streams; draft-specific schedulers must
  handle cross-stream arrival order themselves.

  Datagrams are capability-gated, unreliable, and not fragmented by the
  transport layer. MOQT object delivery code must query capabilities and keep
  each datagram payload within the advertised max size or a conservative
  protocol limit when the backend reports `:unknown`.
  """

  @type listener :: term()
  @type connection :: term()
  @type stream :: term()
  @type event ::
          {:listener_event, listener() | connection(), atom(), term()}
          | {:connection_event, connection(), atom(), term()}
          | {:stream_event, stream(), atom(), term()}
          | {:stream_data, stream(), binary(), map()}
          | {:datagram, connection(), binary(), term()}

  @callback listen(port :: non_neg_integer() | String.t(), opts :: keyword() | map()) ::
              {:ok, listener()} | {:error, term()}

  @callback accept(listener(), opts :: keyword() | map(), timeout()) ::
              {:ok, connection()} | {:error, term()}

  @callback handshake(connection(), timeout()) ::
              {:ok, connection()} | {:error, term()}

  @callback connect(
              String.t() | :inet.ip_address(),
              :inet.port_number(),
              keyword() | map(),
              timeout()
            ) ::
              {:ok, connection()} | {:error, term()}

  @callback open_stream(connection(), opts :: keyword() | map()) ::
              {:ok, stream()} | {:error, term()}

  @callback accept_stream(connection(), opts :: keyword() | map(), timeout()) ::
              {:ok, stream()} | {:error, term()}

  @callback send_stream(stream(), iodata(), opts :: keyword() | map()) ::
              :ok | {:error, term()}

  @callback recv_stream(stream(), byte_count :: non_neg_integer()) ::
              {:ok, binary()} | {:error, term()}

  @callback send_datagram(connection(), binary()) :: :ok | {:error, term()}

  @callback close_stream(stream(), reason :: term()) :: :ok | {:error, term()}

  @callback close_connection(connection(), reason :: term()) :: :ok | {:error, term()}

  @callback set_active(stream(), boolean() | :once | non_neg_integer()) :: :ok | {:error, term()}

  @callback controlling_process(connection() | stream(), pid()) :: :ok | {:error, term()}

  @callback normalize_message(term()) :: event() | :unknown

  @callback capabilities(connection()) :: MOQX.Transport.Capabilities.t() | {:error, term()}

  @doc """
  Returns normalized capabilities for a negotiated transport connection.
  """
  @spec capabilities(module(), connection()) :: MOQX.Transport.Capabilities.t() | {:error, term()}
  def capabilities(transport, connection) do
    transport.capabilities(connection)
  end

  @doc """
  Receives one backend message and normalizes it through the given transport.

  Protocol layers should use this helper instead of matching backend-specific
  messages such as raw `quicer` `{:quic, ...}` tuples.
  """
  @spec receive_event(module(), timeout()) :: event() | :unknown | :timeout
  def receive_event(transport, timeout \\ :infinity)

  def receive_event(transport, :infinity) do
    receive do
      message -> transport.normalize_message(message)
    end
  end

  def receive_event(transport, timeout) do
    receive do
      message -> transport.normalize_message(message)
    after
      timeout -> :timeout
    end
  end
end
