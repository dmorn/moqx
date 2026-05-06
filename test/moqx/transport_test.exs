defmodule MOQX.TransportTest do
  use ExUnit.Case, async: true

  defmodule NormalizingTransport do
    @behaviour MOQX.Transport

    @impl true
    def listen(_port, _opts), do: {:error, :not_used}

    @impl true
    def accept(_listener, _opts, _timeout), do: {:error, :not_used}

    @impl true
    def handshake(_connection, _timeout), do: {:error, :not_used}

    @impl true
    def connect(_host, _port, _opts, _timeout), do: {:error, :not_used}

    @impl true
    def open_stream(_connection, _opts), do: {:error, :not_used}

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :not_used}

    @impl true
    def send_stream(_stream, _data, _opts), do: {:error, :not_used}

    @impl true
    def recv_stream(_stream, _byte_count), do: {:error, :not_used}

    @impl true
    def send_datagram(_connection, _data), do: {:error, :not_used}

    @impl true
    def close_stream(_stream, _reason), do: {:error, :not_used}

    @impl true
    def close_connection(_connection, _reason), do: {:error, :not_used}

    @impl true
    def set_active(_stream, _active), do: {:error, :not_used}

    @impl true
    def controlling_process(_handle, _pid), do: {:error, :not_used}

    @impl true
    def normalize_message({:raw_stream_data, stream, data}) do
      {:stream_data, stream, data, %{}}
    end

    def normalize_message(_message), do: :unknown

    @impl true
    def capabilities(:draft14_connection) do
      %MOQX.Transport.Capabilities{
        alpn: "moq-00",
        datagrams: true,
        max_datagram_size: 1200,
        stream_directions: [:bidirectional, :unidirectional],
        stream_priority: :supported,
        transport_stats: :unsupported
      }
    end

    def capabilities(:moq_lite_connection) do
      %MOQX.Transport.Capabilities{
        alpn: "moq-lite-04",
        datagrams: false,
        max_datagram_size: :unsupported,
        stream_directions: [:bidirectional, :unidirectional],
        stream_priority: :supported,
        transport_stats: :unsupported
      }
    end
  end

  describe "capabilities/2" do
    test "returns normalized draft-14-like capability profiles" do
      assert MOQX.Transport.capabilities(NormalizingTransport, :draft14_connection) ==
               %MOQX.Transport.Capabilities{
                 alpn: "moq-00",
                 datagrams: true,
                 max_datagram_size: 1200,
                 stream_directions: [:bidirectional, :unidirectional],
                 stream_priority: :supported,
                 transport_stats: :unsupported
               }
    end

    test "returns normalized MOQ Lite-like capability profiles" do
      assert MOQX.Transport.capabilities(NormalizingTransport, :moq_lite_connection) ==
               %MOQX.Transport.Capabilities{
                 alpn: "moq-lite-04",
                 datagrams: false,
                 max_datagram_size: :unsupported,
                 stream_directions: [:bidirectional, :unidirectional],
                 stream_priority: :supported,
                 transport_stats: :unsupported
               }
    end
  end

  describe "receive_event/2" do
    test "returns normalized transport events from the given transport" do
      send(self(), {:raw_stream_data, :stream, "payload"})

      assert MOQX.Transport.receive_event(NormalizingTransport, 0) ==
               {:stream_data, :stream, "payload", %{}}
    end

    test "returns unknown for backend messages the transport does not recognize" do
      send(self(), {:unrecognized_backend_message, :data})

      assert MOQX.Transport.receive_event(NormalizingTransport, 0) == :unknown
    end

    test "returns timeout when no backend message arrives" do
      assert MOQX.Transport.receive_event(NormalizingTransport, 0) == :timeout
    end
  end
end
