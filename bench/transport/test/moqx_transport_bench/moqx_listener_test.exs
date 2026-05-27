defmodule MOQX.TransportBench.MoqxListenerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias MOQX.TransportBench.DatagramPayload
  alias MOQX.TransportBench.JSONL
  alias MOQX.TransportBench.MoqxListener

  test "datagram pressure writes receiver diagnostics and exits after idle timeout" do
    dir = tmp_dir()
    output_path = Path.join(dir, "listener-diagnostics.jsonl")
    certfile = Path.join(dir, "server.pem")
    keyfile = Path.join(dir, "server-key.pem")
    File.write!(certfile, "cert")
    File.write!(keyfile, "key")

    Process.put({__MODULE__.DatagramTransport, :datagrams}, [1, 2])

    stdout =
      capture_io(fn ->
        MoqxListener.main(
          [
            "--certfile",
            certfile,
            "--keyfile",
            keyfile,
            "--workload",
            "datagram_pressure",
            "--datagram-size",
            "64",
            "--datagram-count",
            "3",
            "--datagram-idle-timeout-ms",
            "10",
            "--timeout-seconds",
            "1",
            "--diagnostics-output",
            output_path
          ],
          script: "test moqx-listener",
          transport_backend: __MODULE__.DatagramTransport,
          ensure_quicer?: false
        )
      end)

    assert stdout =~ "moqx-listener ready"
    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()

    assert record["schema_version"] == "moqx-listener-diagnostics-v1"
    assert record["record_type"] == "datagram_listener_run"
    assert record["workload"] == "datagram_pressure"

    assert record["summary"]["expected_datagrams"] == 3
    assert record["summary"]["datagrams_received"] == 2
    assert record["summary"]["datagrams_unique"] == 2
    assert record["summary"]["datagrams_missing"] == 1
    assert record["summary"]["datagrams_echo_attempted"] == 2
    assert record["summary"]["datagrams_echoed"] == 2
    assert record["summary"]["stop_reason"] == "datagram_idle_timeout"
    assert record["summary"]["first_datagram_received_ms"] >= 0

    assert record["summary"]["last_datagram_received_ms"] >=
             record["summary"]["first_datagram_received_ms"]

    assert record["summary"]["first_echo_attempted_ms"] >=
             record["summary"]["first_datagram_received_ms"]

    assert record["summary"]["last_echo_attempted_ms"] >=
             record["summary"]["first_echo_attempted_ms"]

    assert record["summary"]["echo_send_duration_ms"]["count"] == 2
    assert record["summary"]["echo_send_duration_ms"]["total"] >= 0
    assert record["summary"]["echo_send_duration_ms"]["max"] >= 0

    assert is_integer(record["process"]["message_queue_len"])
    assert is_integer(record["process"]["message_queue_len_peak"])
    assert record["process"]["message_queue_len_peak"] >= record["process"]["message_queue_len"]

    assert [%{"sample_index" => 1, "message_queue_len" => first_sample} | _] =
             record["process"]["message_queue_len_sample_points"]

    assert is_integer(first_sample)
  end

  test "datagram pressure writes listener diagnostics when accept times out" do
    dir = tmp_dir()
    output_path = Path.join(dir, "listener-diagnostics.jsonl")
    certfile = Path.join(dir, "server.pem")
    keyfile = Path.join(dir, "server-key.pem")
    File.write!(certfile, "cert")
    File.write!(keyfile, "key")

    Process.put({__MODULE__.DatagramTransport, :accept_error}, :timeout)

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            assert {:error, :timeout} =
                     MoqxListener.main(
                       [
                         "--host",
                         "0.0.0.0",
                         "--port",
                         "55455",
                         "--certfile",
                         certfile,
                         "--keyfile",
                         keyfile,
                         "--workload",
                         "datagram_pressure",
                         "--datagram-size",
                         "64",
                         "--datagram-count",
                         "3",
                         "--timeout-seconds",
                         "1",
                         "--diagnostics-output",
                         output_path
                       ],
                       script: "test moqx-listener",
                       transport_backend: __MODULE__.DatagramTransport,
                       ensure_quicer?: false,
                       halt_on_error?: false
                     )
          end)

        send(self(), {:moqx_listener_stdout, stdout})
      end)

    assert stderr =~ ":timeout"
    assert_receive {:moqx_listener_stdout, stdout}
    assert stdout =~ "moqx-listener ready"

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert record["schema_version"] == "moqx-listener-diagnostics-v1"
    assert record["record_type"] == "listener_accept_run"
    assert record["workload"] == "datagram_pressure"
    assert record["alpn"] == "moqx-test"

    assert record["listener"] == %{
             "configured_host" => "0.0.0.0",
             "configured_port" => 55_455,
             "bound_ip" => "127.0.0.1",
             "bound_port" => 4433
           }

    assert record["summary"]["phase"] == "accept"
    assert record["summary"]["stop_reason"] == "accept_error"
    assert record["summary"]["error_reason"] == "timeout"
    assert record["summary"]["connections_served"] == 0
    assert record["summary"]["connection_count_limit"] == 1
    assert record["summary"]["timeout_ms"] == 1000

    assert is_integer(record["process"]["message_queue_len"])
    assert is_integer(record["process"]["message_queue_len_peak"])
  end

  test "datagram pressure keeps accept timeout separate from workload timeout" do
    dir = tmp_dir()
    output_path = Path.join(dir, "listener-diagnostics.jsonl")
    certfile = Path.join(dir, "server.pem")
    keyfile = Path.join(dir, "server-key.pem")
    File.write!(certfile, "cert")
    File.write!(keyfile, "key")

    Process.put({__MODULE__.DatagramTransport, :datagrams}, [1])

    capture_io(fn ->
      MoqxListener.main(
        [
          "--certfile",
          certfile,
          "--keyfile",
          keyfile,
          "--workload",
          "datagram_pressure",
          "--datagram-size",
          "64",
          "--datagram-count",
          "1",
          "--timeout-seconds",
          "1",
          "--accept-timeout-seconds",
          "60",
          "--diagnostics-output",
          output_path
        ],
        script: "test moqx-listener",
        transport_backend: __MODULE__.DatagramTransport,
        ensure_quicer?: false
      )
    end)

    assert Process.get({__MODULE__.DatagramTransport, :accept_timeout}) == 60_000

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert record["record_type"] == "datagram_listener_run"
    assert record["summary"]["datagram_observation_timeout_ms"] == 1000
  end

  test "stream pressure writes listener-side diagnostics" do
    dir = tmp_dir()
    output_path = Path.join(dir, "stream-listener-diagnostics.jsonl")
    certfile = Path.join(dir, "server.pem")
    keyfile = Path.join(dir, "server-key.pem")
    File.write!(certfile, "cert")
    File.write!(keyfile, "key")

    Process.put({__MODULE__.StreamTransport, :accepted}, 0)

    capture_io(fn ->
      MoqxListener.main(
        [
          "--certfile",
          certfile,
          "--keyfile",
          keyfile,
          "--workload",
          "stream_pressure",
          "--stream-count",
          "2",
          "--payload-size",
          "32",
          "--payload-count",
          "2",
          "--timeout-seconds",
          "1",
          "--diagnostics-output",
          output_path
        ],
        script: "test moqx-listener",
        transport_backend: __MODULE__.StreamTransport,
        ensure_quicer?: false
      )
    end)

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert record["schema_version"] == "moqx-listener-diagnostics-v1"
    assert record["record_type"] == "stream_listener_run"
    assert record["workload"] == "stream_pressure"

    assert record["summary"]["expected_streams"] == 2
    assert record["summary"]["streams_accepted"] == 2
    assert record["summary"]["streams_completed"] == 2
    assert record["summary"]["bytes_expected"] == 128
    assert record["summary"]["bytes_received"] == 128
    assert record["summary"]["stream_receive_events"] == 4
    assert record["summary"]["echo_send_attempted"] == 4
    assert record["summary"]["echo_send_accepted"] == 4
    assert record["summary"]["send_completed"] == 4
    assert record["summary"]["send_completions_pending"] == 0
    assert record["summary"]["stop_reason"] == "streams_completed"
    assert is_number(record["summary"]["duration_ms"])

    assert [
             %{"index" => 1, "bytes_received" => 64, "completed" => true},
             %{"index" => 2, "bytes_received" => 64, "completed" => true}
           ] = record["streams"]

    assert record["process"]["message_queue_len_samples"] > 0

    assert [%{"sample_index" => 1, "message_queue_len" => first_sample} | _] =
             record["process"]["message_queue_len_sample_points"]

    assert is_integer(first_sample)
  end

  test "stream pressure separates echo-send attempts from accepted sends" do
    dir = tmp_dir()
    output_path = Path.join(dir, "stream-listener-diagnostics.jsonl")
    certfile = Path.join(dir, "server.pem")
    keyfile = Path.join(dir, "server-key.pem")
    File.write!(certfile, "cert")
    File.write!(keyfile, "key")

    Process.put({__MODULE__.StreamTransport, :accepted}, 0)
    Process.put({__MODULE__.StreamTransport, :fail_send_after}, 0)

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, :send_failed} =
                 MoqxListener.main(
                   [
                     "--certfile",
                     certfile,
                     "--keyfile",
                     keyfile,
                     "--workload",
                     "stream_pressure",
                     "--stream-count",
                     "1",
                     "--payload-size",
                     "32",
                     "--payload-count",
                     "1",
                     "--timeout-seconds",
                     "1",
                     "--diagnostics-output",
                     output_path
                   ],
                   script: "test moqx-listener",
                   transport_backend: __MODULE__.StreamTransport,
                   ensure_quicer?: false,
                   halt_on_error?: false
                 )
      end)

    assert stderr =~ ":send_failed"

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert record["summary"]["echo_send_attempted"] == 1
    assert record["summary"]["echo_send_accepted"] == 0
    assert record["summary"]["send_completed"] == 0
    assert record["summary"]["send_completions_pending"] == 0
    assert record["summary"]["streams_failed"] == 1
    assert record["summary"]["stop_reason"] == "stream_error"
    assert record["summary"]["error_reason"] == "send_failed"
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "moqx-listener-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defmodule DatagramTransport do
    @behaviour MOQX.Transport

    @impl true
    def listen(_port, _opts), do: {:ok, :listener}

    @impl true
    def local_address(:listener), do: {:ok, {{127, 0, 0, 1}, 4433}}
    def local_address(:connection), do: {:ok, {{127, 0, 0, 1}, 4433}}

    @impl true
    def close_listener(:listener, _timeout), do: :ok

    @impl true
    def accept(:listener, _opts, timeout) do
      Process.put({__MODULE__, :accept_timeout}, timeout)

      if reason = Process.get({__MODULE__, :accept_error}) do
        {:error, reason}
      else
        Process.put({__MODULE__, :echoed}, 0)

        for sequence <- Process.get({__MODULE__, :datagrams}, []) do
          payload = DatagramPayload.encode(sequence, 64, System.monotonic_time(:microsecond))
          send(self(), {:moqx_transport, {:datagram, :connection, payload, %{}}})
        end

        {:ok, :connection}
      end
    end

    @impl true
    def handshake(:connection, _timeout), do: {:ok, :connection}

    @impl true
    def connect(_host, _port, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def open_stream(_connection, _opts), do: {:error, :unsupported}

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream(_stream, _data, _opts), do: {:error, :unsupported}

    @impl true
    def recv_stream(_stream, _byte_count), do: {:error, :unsupported}

    @impl true
    def send_datagram(:connection, _data) do
      echoed = Process.get({__MODULE__, :echoed}, 0) + 1
      Process.put({__MODULE__, :echoed}, echoed)

      Process.send_after(
        self(),
        {:moqx_transport, {:connection_event, :connection, :closed, %{}}},
        20
      )

      :ok
    end

    @impl true
    def finish_sending(_stream), do: :ok

    @impl true
    def abort_sending(_stream, _error_code), do: :ok

    @impl true
    def abort_receiving(_stream, _error_code), do: :ok

    @impl true
    def close_connection(:connection, _error_code), do: :ok

    @impl true
    def set_active(_stream, _active), do: :ok

    @impl true
    def controlling_process(_handle, _pid), do: :ok

    @impl true
    def normalize_message(_message), do: :unknown

    @impl true
    def capabilities(_connection), do: %MOQX.Transport.Capabilities{}
  end

  defmodule StreamTransport do
    @behaviour MOQX.Transport

    alias MOQX.Transport.StreamInfo

    @impl true
    def listen(_port, _opts), do: {:ok, :listener}

    @impl true
    def local_address(:listener), do: {:ok, {{127, 0, 0, 1}, 4433}}
    def local_address(:connection), do: {:ok, {{127, 0, 0, 1}, 4433}}

    @impl true
    def close_listener(:listener, _timeout), do: :ok

    @impl true
    def accept(:listener, _opts, _timeout) do
      Process.send_after(
        self(),
        {:moqx_transport, {:connection_event, :connection, :closed, %{}}},
        20
      )

      {:ok, :connection}
    end

    @impl true
    def handshake(:connection, _timeout), do: {:ok, :connection}

    @impl true
    def connect(_host, _port, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def open_stream(_connection, _opts), do: {:error, :unsupported}

    @impl true
    def accept_stream(:connection, _opts, _timeout) do
      accepted = Process.get({__MODULE__, :accepted}, 0) + 1
      Process.put({__MODULE__, :accepted}, accepted)
      {:ok, {:stream, accepted}}
    end

    @impl true
    def stream_info({:stream, index}, :server, :peer) do
      {:ok,
       %StreamInfo{
         stream_id: index,
         direction: :bidirectional,
         initiator: :peer,
         initiator_role: :client,
         local_role: :server,
         send_side?: true,
         receive_side?: true
       }}
    end

    @impl true
    def send_stream(stream, _data, _opts) do
      attempts = Process.get({__MODULE__, :send_attempts}, 0)
      Process.put({__MODULE__, :send_attempts}, attempts + 1)

      case Process.get({__MODULE__, :fail_send_after}) do
        fail_after when is_integer(fail_after) and attempts >= fail_after ->
          {:error, :send_failed}

        _other ->
          send(self(), {:moqx_transport, {:stream_event, stream, :send_completed, %{}}})
          :ok
      end
    end

    @impl true
    def recv_stream({:stream, index}, byte_count) do
      key = {__MODULE__, :received, index}
      received = Process.get(key, 0)

      if received < 64 do
        Process.put(key, received + byte_count)
        {:ok, :binary.copy(<<index>>, byte_count)}
      else
        {:error, :peer_send_shutdown}
      end
    end

    @impl true
    def send_datagram(_connection, _data), do: {:error, :unsupported}

    @impl true
    def finish_sending(_stream), do: :ok

    @impl true
    def abort_sending(_stream, _error_code), do: :ok

    @impl true
    def abort_receiving(_stream, _error_code), do: :ok

    @impl true
    def close_connection(:connection, _error_code), do: :ok

    @impl true
    def set_active(_stream, _active), do: :ok

    @impl true
    def controlling_process(_handle, _pid), do: :ok

    @impl true
    def normalize_message(_message), do: :unknown

    @impl true
    def capabilities(_connection), do: %MOQX.Transport.Capabilities{}
  end
end
