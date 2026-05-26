defmodule MOQX.TransportBench.ReferenceComparisonTest do
  use ExUnit.Case, async: true

  alias MOQX.TransportBench.Contract
  alias MOQX.TransportBench.JSONL
  alias MOQX.TransportBench.ReferenceComparison

  test "emits a valid reference comparison record from quicprobe JSON" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference.jsonl")
    args_path = Path.join(dir, "quicprobe.args")
    fake_quicprobe = fake_quicprobe_command(dir, args_path)

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-reference-server",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--alpn",
        "moqx-test",
        "--stream-count",
        "2",
        "--payload-size",
        "256",
        "--payload-count",
        "4",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["workload"]["family"] == "reference_comparison"
    assert record["workload"]["stream_direction"] == "bidirectional"
    assert record["workload"]["stream_count"] == 2
    assert record["workload"]["payload_size_bytes"] == 256
    assert record["metrics"]["bytes_sent"] == 2048
    assert record["metrics"]["bytes_received"] == 2048
    assert record["metrics"]["goodput_bps"] == 32_000_000.0
    assert record["software"]["reference_implementation"] == "quic-go"
    assert record["software"]["reference_version"] == "v0.50.1"
    assert record["profile"]["settings"]["topology"] == "reference-client-to-reference-server"
    assert record["profile"]["settings"]["workload"] == "stream_pressure"
    assert record["profile"]["settings"]["stream_scheduling"] == "concurrent"
    assert record["profile"]["settings"]["server_implementation"] == "quicprobe"

    args = File.read!(args_path)
    assert args =~ "client"
    assert args =~ "--json"
    assert args =~ "--addr 127.0.0.1:4433"
    assert args =~ "--workload stream_pressure"
    assert args =~ "--stream-count 2"
    assert args =~ "--payload-size 256"
    assert args =~ "--payload-count 4"
  end

  test "emits a valid reference client to MOQX listener record from quicprobe JSON" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference-client-moqx-listener.jsonl")
    args_path = Path.join(dir, "quicprobe-listener.args")
    fake_quicprobe = fake_quicprobe_command(dir, args_path)

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-moqx-listener",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--stream-count",
        "2",
        "--payload-size",
        "256",
        "--payload-count",
        "4",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-client-listener-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["workload"]["family"] == "reference_comparison"
    assert record["workload"]["tool"] == "quicprobe"
    assert record["workload"]["topology"] == "reference-client-to-moqx-listener"
    assert record["profile"]["settings"]["topology"] == "reference-client-to-moqx-listener"
    assert record["profile"]["settings"]["workload"] == "stream_pressure"
    assert record["profile"]["settings"]["client_implementation"] == "quicprobe"
    assert record["profile"]["settings"]["server_implementation"] == "moqx"
    assert record["profile"]["settings"]["stream_scheduling"] == "concurrent"
    assert record["metrics"]["bytes_sent"] == 2048
    assert record["metrics"]["bytes_received"] == 2048

    args = File.read!(args_path)
    assert args =~ "client"
    assert args =~ "--json"
    assert args =~ "--addr 127.0.0.1:4433"
    assert args =~ "--workload stream_pressure"
    assert args =~ "--stream-count 2"
    assert args =~ "--payload-size 256"
    assert args =~ "--payload-count 4"
  end

  test "emits a valid datagram pressure record from quicprobe JSON" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference-datagram.jsonl")
    args_path = Path.join(dir, "quicprobe-datagram.args")
    fake_quicprobe = fake_quicprobe_command(dir, args_path, datagram_quicprobe_json())

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-reference-server",
        "--workload",
        "datagram_pressure",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--datagram-size",
        "64",
        "--datagram-count",
        "4",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-datagram-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["profile"]["datagrams"] == true
    assert record["profile"]["settings"]["workload"] == "datagram_pressure"
    assert record["profile"]["settings"]["datagram_mode"] == "burst"
    assert record["profile"]["settings"]["stream_scheduling"] == :null
    assert record["workload"]["stream_count"] == :null
    assert record["workload"]["datagram_size_bytes"] == 64
    assert record["workload"]["datagrams_per_second"] == 4000.0
    assert record["metrics"]["bytes_sent"] == 256
    assert record["metrics"]["bytes_received"] == 192
    assert record["metrics"]["send_rate_datagrams_per_second"] == 4000.0
    assert record["metrics"]["delivered_datagrams_per_second"] == 1500.0
    assert record["metrics"]["datagram_delivery_ratio"] == 0.75
    assert record["metrics"]["datagram_drop_count"] == 1
    assert record["metrics"]["latency_p50_ms"] == 0.2
    assert record["limits"]["first_break_symptom"] == "datagram_delivery_loss"
    assert record["limits"]["stopped_by"] == "datagram_delivery_loss"
    assert record["errors"]["message"] == :null

    args = File.read!(args_path)
    assert args =~ "--workload datagram_pressure"
    assert args =~ "--datagram-size 64"
    assert args =~ "--datagram-count 4"
  end

  test "emits paced datagram pressure fields and threshold stop condition" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference-paced-datagram.jsonl")
    args_path = Path.join(dir, "quicprobe-paced-datagram.args")
    fake_quicprobe = fake_quicprobe_command(dir, args_path, paced_datagram_quicprobe_json())

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-reference-server",
        "--workload",
        "datagram_pressure",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--datagram-size",
        "64",
        "--datagram-rate",
        "5",
        "--duration-seconds",
        "2",
        "--delivery-threshold",
        "0.95",
        "--offered-rate-tolerance",
        "0.9",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-paced-datagram-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["profile"]["settings"]["datagram_mode"] == "paced"
    assert record["profile"]["settings"]["delivery_threshold"] == 0.95
    assert record["profile"]["settings"]["offered_rate_tolerance"] == 0.9
    assert record["profile"]["pacing"] == "paced"
    assert record["workload"]["datagrams_per_second"] == 5.0
    assert record["workload"]["offered_load_bps"] == 2560.0
    assert record["metrics"]["offered_load_bps"] == 2560.0
    assert record["metrics"]["offered_rate_ratio"] == 1.0
    assert record["metrics"]["datagram_delivery_ratio"] == 0.9
    assert record["metrics"]["datagram_drop_count"] == 1
    assert record["limits"]["first_break_symptom"] == "datagram_delivery_loss"

    args = File.read!(args_path)
    assert args =~ "--workload datagram_pressure"
    assert args =~ "--datagram-size 64"
    assert args =~ "--datagram-rate 5"
    assert args =~ "--duration-seconds 2"
    assert args =~ "--offered-rate-tolerance 0.9"
    assert args =~ "--timeout 7s"
  end

  test "marks paced datagram results invalid when the generator misses the target offered rate" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference-paced-invalid.jsonl")

    fake_quicprobe =
      fake_quicprobe_command(
        dir,
        Path.join(dir, "quicprobe-paced-invalid.args"),
        paced_datagram_quicprobe_json(offered_rate_ratio: 0.8, offered_rate_valid: false)
      )

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-reference-server",
        "--workload",
        "datagram_pressure",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--datagram-size",
        "64",
        "--datagram-rate",
        "5",
        "--duration-seconds",
        "2",
        "--delivery-threshold",
        "0.95",
        "--offered-rate-tolerance",
        "0.95",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-paced-invalid-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?
    assert record["limits"]["first_break_symptom"] == "tool_output_invalid"
    assert record["limits"]["stopped_by"] == "reference_comparison_invalid_measurement"
    assert record["limits"]["protocol_error"] == true
    assert record["errors"]["message"] =~ "offered rate below tolerance"
    assert record["errors"]["message"] =~ "0.8 < 0.95"
  end

  test "records structured diagnostics when MOQX bidirectional echo closes early" do
    dir = tmp_dir()
    output_path = Path.join(dir, "moqx-peer-shutdown.jsonl")

    ReferenceComparison.main(
      [
        "--topology",
        "moqx-client-to-reference-server",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--stream-direction",
        "bidirectional",
        "--stream-count",
        "2",
        "--payload-size",
        "256",
        "--payload-count",
        "4",
        "--output",
        output_path,
        "--run-id",
        "moqx-peer-shutdown-test"
      ],
      script: "test reference-comparison",
      transport_backend: __MODULE__.PeerShutdownTransport
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["limits"]["first_break_symptom"] == "stream_closed_before_expected_bytes"
    assert record["limits"]["stopped_by"] == "stream_closed_before_expected_bytes"
    assert record["limits"]["protocol_error"] == true
    assert record["errors"]["message"] =~ "reason=peer_send_shutdown"
    assert record["errors"]["details"]["bytes_expected"] == 1024
    assert record["metrics"]["bytes_sent"] == 2048
    assert record["metrics"]["bytes_received"] == 0

    diagnostics = record["diagnostics"]
    assert diagnostics["version"] == "stream-pressure-diagnostics-v1"
    assert diagnostics["summary"]["streams_opened"] == 2
    assert diagnostics["summary"]["streams_failed"] == 1
    assert diagnostics["summary"]["bytes_sent"] == 2048
    assert diagnostics["summary"]["bytes_received"] == 0

    assert [
             %{"phase" => "echo_failed", "error" => "peer_send_shutdown"},
             %{"phase" => "receiving_echo"}
           ] = diagnostics["streams"]
  end

  defp fake_quicprobe_command(dir, args_path) do
    fake_quicprobe_command(dir, args_path, stream_quicprobe_json())
  end

  defp fake_quicprobe_command(dir, args_path, json) do
    script_path = Path.join(dir, "fake-quicprobe")

    File.write!(script_path, """
    #!/usr/bin/env sh
    printf '%s' "$*" > '#{args_path}'
    cat <<'JSON'
    #{json}
    JSON
    """)

    File.chmod!(script_path, 0o755)
    script_path
  end

  defp stream_quicprobe_json do
    """
    {
      "schema_version": "quicprobe-v1",
      "record_type": "client_run",
      "tool": "quicprobe",
      "reference_implementation": "quic-go",
      "reference_version": "v0.50.1",
      "started_at": "2026-05-21T10:15:13Z",
      "finished_at": "2026-05-21T10:15:14Z",
      "remote_addr": "127.0.0.1:4433",
      "alpn": "moqx-test",
      "stream_direction": "bidirectional",
      "stream_count": 2,
      "payload_size_bytes": 256,
      "payload_count": 4,
      "bytes_sent": 2048,
      "bytes_received": 2048,
      "handshake_latency_ms": 6.5,
      "first_byte_latency_ms": 0.4,
      "application_duration_ms": 0.512,
      "goodput_bps": 32000000.0,
      "stream_latency_ms": {
        "p50": 0.4,
        "p95": 0.5,
        "p99": 0.5
      }
    }
    """
  end

  defp datagram_quicprobe_json do
    """
    {
      "schema_version": "quicprobe-v1",
      "record_type": "client_run",
      "tool": "quicprobe",
      "reference_implementation": "quic-go",
      "reference_version": "v0.50.1",
      "started_at": "2026-05-21T10:15:13Z",
      "finished_at": "2026-05-21T10:15:14Z",
      "remote_addr": "127.0.0.1:4433",
      "alpn": "moqx-test",
      "workload": "datagram_pressure",
      "payload_size_bytes": 64,
      "datagram_size_bytes": 64,
      "datagram_count": 4,
      "datagram_mode": "burst",
      "datagrams_offered": 4,
      "datagrams_accepted": 4,
      "datagrams_received": 3,
      "datagram_delivery_ratio": 0.75,
      "datagram_drop_count": 1,
      "bytes_sent": 256,
      "bytes_received": 192,
      "handshake_latency_ms": 6.5,
      "first_byte_latency_ms": 0.4,
      "application_duration_ms": 2.0,
      "goodput_bps": 768000.0,
      "send_rate_datagrams_per_second": 4000.0,
      "datagram_latency_ms": {
        "p50": 0.2,
        "p95": 0.4,
        "p99": 0.4
      }
    }
    """
  end

  defp paced_datagram_quicprobe_json(overrides \\ []) do
    offered_rate_ratio = Keyword.get(overrides, :offered_rate_ratio, 1.0)
    offered_rate_valid = Keyword.get(overrides, :offered_rate_valid, true)

    """
    {
      "schema_version": "quicprobe-v1",
      "record_type": "client_run",
      "tool": "quicprobe",
      "reference_implementation": "quic-go",
      "reference_version": "v0.50.1",
      "started_at": "2026-05-21T10:15:13Z",
      "finished_at": "2026-05-21T10:15:15Z",
      "remote_addr": "127.0.0.1:4433",
      "alpn": "moqx-test",
      "workload": "datagram_pressure",
      "payload_size_bytes": 64,
      "datagram_size_bytes": 64,
      "datagram_count": 10,
      "datagram_mode": "paced",
      "target_datagrams_per_second": 5.0,
      "target_duration_seconds": 2,
      "offered_rate_ratio": #{offered_rate_ratio},
      "offered_rate_tolerance": 0.95,
      "offered_rate_valid": #{offered_rate_valid},
      "datagrams_offered": 10,
      "datagrams_accepted": 10,
      "datagrams_received": 9,
      "datagram_delivery_ratio": 0.9,
      "datagram_drop_count": 1,
      "bytes_sent": 640,
      "bytes_received": 576,
      "handshake_latency_ms": 6.5,
      "first_byte_latency_ms": 0.4,
      "application_duration_ms": 2000.0,
      "offered_load_bps": 2560.0,
      "goodput_bps": 2304.0,
      "send_rate_datagrams_per_second": 5.0,
      "datagram_latency_ms": {
        "p50": 0.2,
        "p95": 0.4,
        "p99": 0.4
      }
    }
    """
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "moqx-reference-comparison-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defmodule PeerShutdownTransport do
    @behaviour MOQX.Transport

    @impl true
    def listen(_port, _opts), do: {:error, :unsupported}

    @impl true
    def accept(_listener, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def handshake(connection, _timeout), do: {:ok, connection}

    @impl true
    def connect(_host, _port, _opts, _timeout), do: {:ok, :connection}

    @impl true
    def open_stream(_connection, _opts), do: {:ok, {:stream, make_ref()}}

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream(stream, _data, opts) do
      if Keyword.get(opts, :finish, false) do
        send(self(), {:moqx_transport, {:stream_event, stream, :peer_finished_sending, %{}}})
      end

      :ok
    end

    @impl true
    def recv_stream(_stream, _byte_count), do: {:error, :peer_send_shutdown}

    @impl true
    def send_datagram(_connection, _data), do: {:error, :unsupported}

    @impl true
    def finish_sending(_stream), do: :ok

    @impl true
    def abort_sending(_stream, _error_code), do: :ok

    @impl true
    def abort_receiving(_stream, _error_code), do: :ok

    @impl true
    def close_connection(_connection, _error_code), do: :ok

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
