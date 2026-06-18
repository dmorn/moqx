defmodule MOQXProbe.Benchee.EvidenceCollectorTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Benchee.Adapters.FakeTransport
  alias MOQXProbe.Benchee.Adapters.Quicprobe
  alias MOQXProbe.Benchee.Evidence
  alias MOQXProbe.Benchee.EvidenceCollector
  alias MOQXProbe.Benchee.RunReceipt

  test "collects fake transport evidence from explicit state" do
    {:ok, collector} = EvidenceCollector.start(run_id: "suite-1")

    receipt =
      RunReceipt.new!(
        id: :fake_run,
        target: :fake,
        scenario: "object-stream",
        input: "tiny",
        implementation: "stream_owner",
        expected: %{stream_bytes_received: 384, streams_completed: 1}
      )

    assert {:ok, %Evidence{valid: true, status: :valid} = evidence} =
             EvidenceCollector.collect(collector, FakeTransport, receipt,
               source: %{
                 fake_run: %{stream_bytes_received: 384, streams_completed: 1}
               }
             )

    assert evidence.observed.stream_bytes_received == 384

    assert EvidenceCollector.summary(collector) == %{
             total: 1,
             valid: 1,
             invalid: 0,
             timeout: 0,
             error: 0,
             missing: 0
           }

    assert [
             %{
               receipt: %RunReceipt{id: :fake_run},
               evidence: %Evidence{status: :valid}
             }
           ] = EvidenceCollector.records(collector)

    EvidenceCollector.stop(collector)
  end

  test "records invalid fake transport evidence without changing timing samples" do
    {:ok, collector} = EvidenceCollector.start()

    receipt =
      RunReceipt.new!(
        id: :mismatch,
        target: :fake,
        expected: %{stream_bytes_received: 384, streams_completed: 1}
      )

    hook =
      EvidenceCollector.after_each(collector, FakeTransport,
        source: fn _receipt -> %{stream_bytes_received: 128, streams_completed: 1} end
      )

    assert ^receipt = hook.(receipt)

    assert [
             %{
               evidence: %Evidence{
                 valid: false,
                 status: :invalid,
                 mismatches: [%{field: :stream_bytes_received, expected: 384, observed: 128}]
               }
             }
           ] = EvidenceCollector.records(collector)
  end

  test "writes sidecar evidence JSONL using Elixir's JSON wrapper" do
    {:ok, collector} = EvidenceCollector.start(run_id: "suite-jsonl")

    receipt =
      RunReceipt.new!(
        id: :jsonl_run,
        target: :fake,
        expected: %{datagrams_received: 2}
      )

    assert {:ok, %Evidence{}} =
             EvidenceCollector.collect(collector, FakeTransport, receipt,
               source: %{datagrams_received: 2}
             )

    path = Path.join(System.tmp_dir!(), "moqxprobe-evidence-#{System.unique_integer()}.jsonl")
    on_exit(fn -> File.rm(path) end)

    assert :ok = EvidenceCollector.write_jsonl(collector, path)

    assert [decoded] =
             path
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&JSON.decode!/1)

    assert decoded["schema_version"] == "moqxprobe-benchee-evidence-v1"
    assert decoded["record_type"] == "delivery_evidence"
    assert decoded["run_id"] == "suite-jsonl"
    assert decoded["receipt"]["id"] == "jsonl_run"
    assert decoded["evidence"]["receipt_id"] == "jsonl_run"
    assert decoded["evidence"]["valid"] == true
    assert decoded["evidence"]["error"] == nil
    assert decoded["evidence"]["observed"]["datagrams_received"] == 2
  end

  test "quicprobe adapter reads matching server_run_evidence JSONL" do
    path = temp_jsonl_path()
    on_exit(fn -> File.rm(path) end)

    write_jsonl!(path, [
      %{
        record_type: "server_run_evidence",
        run_sequence: 1,
        stream_bytes_received: 10,
        streams_completed: 1,
        receiver_evidence_complete: true
      },
      %{
        record_type: "server_run_evidence",
        run_sequence: 2,
        stream_bytes_received: 384,
        stream_bytes_echo_accepted: 0,
        streams_completed: 1,
        receiver_evidence_complete: true
      }
    ])

    receipt =
      RunReceipt.new!(
        id: :quicprobe_run,
        target: :quicprobe,
        match: %{run_sequence: 2},
        expected: %{
          stream_bytes_received: 384,
          stream_bytes_echo_accepted: 0,
          streams_completed: 1,
          receiver_evidence_complete: true
        }
      )

    assert {:ok, %Evidence{valid: true, source: :quicprobe} = evidence} =
             Quicprobe.collect(receipt, path: path, timeout_ms: 10, poll_ms: 1)

    assert evidence.observed.stream_bytes_received == 384
    assert evidence.metadata.raw["run_sequence"] == 2
  end

  test "quicprobe adapter matches the first evidence record after a cursor" do
    path = temp_jsonl_path()
    on_exit(fn -> File.rm(path) end)

    write_jsonl!(path, [
      %{
        record_type: "server_run_evidence",
        run_sequence: 1,
        stream_bytes_received: 128,
        streams_completed: 1,
        receiver_evidence_complete: true
      },
      %{
        record_type: "server_run_evidence",
        run_sequence: 2,
        stream_bytes_received: 384,
        streams_completed: 1,
        receiver_evidence_complete: true
      },
      %{
        record_type: "server_run_evidence",
        run_sequence: 3,
        stream_bytes_received: 999,
        streams_completed: 1,
        receiver_evidence_complete: true
      }
    ])

    receipt =
      RunReceipt.new!(
        id: :after_cursor,
        target: :quicprobe,
        match: %{after_run_sequence: 1},
        expected: %{stream_bytes_received: 384, streams_completed: 1}
      )

    assert {:ok, %Evidence{valid: true} = evidence} =
             Quicprobe.collect(receipt, path: path, timeout_ms: 10, poll_ms: 1)

    assert evidence.metadata.raw["run_sequence"] == 2
  end

  test "quicprobe adapter reports the last observed run sequence" do
    path = temp_jsonl_path()
    on_exit(fn -> File.rm(path) end)

    assert {:ok, 0} = Quicprobe.last_run_sequence(path)

    write_jsonl!(path, [
      %{record_type: "server_run_evidence", run_sequence: 1},
      %{record_type: "ignored", run_sequence: 9},
      %{record_type: "server_run_evidence", run_sequence: 3}
    ])

    assert {:ok, 3} = Quicprobe.last_run_sequence(path)
  end

  test "quicprobe adapter returns timeout evidence when no matching record appears" do
    path = temp_jsonl_path()
    on_exit(fn -> File.rm(path) end)

    write_jsonl!(path, [%{record_type: "server_run_evidence", run_sequence: 1}])

    receipt =
      RunReceipt.new!(
        id: :missing_quicprobe_run,
        target: :quicprobe,
        match: %{run_sequence: 99},
        expected: %{stream_bytes_received: 384}
      )

    assert {:ok, %Evidence{valid: false, status: :timeout, error: {:timeout, 0}}} =
             Quicprobe.collect(receipt, path: path, timeout_ms: 0, poll_ms: 1)
  end

  test "quicprobe adapter records malformed JSONL as evidence error" do
    path = temp_jsonl_path()
    on_exit(fn -> File.rm(path) end)

    File.write!(path, "{not json}\n")

    receipt =
      RunReceipt.new!(
        id: :bad_jsonl,
        target: :quicprobe,
        expected: %{stream_bytes_received: 384}
      )

    assert {:ok, %Evidence{valid: false, status: :error, error: {:invalid_jsonl, _reason}}} =
             Quicprobe.collect(receipt, path: path, timeout_ms: 0, poll_ms: 1)
  end

  test "quicprobe adapter requires an explicit evidence path" do
    receipt =
      RunReceipt.new!(
        id: :missing_path,
        target: :quicprobe,
        expected: %{stream_bytes_received: 384}
      )

    assert {:error, :missing_quicprobe_evidence_path} = Quicprobe.collect(receipt, [])
  end

  defp temp_jsonl_path do
    Path.join(System.tmp_dir!(), "moqxprobe-quicprobe-#{System.unique_integer()}.jsonl")
  end

  defp write_jsonl!(path, records) do
    content = Enum.map_join(records, "", fn record -> json_encode!(record) <> "\n" end)
    File.write!(path, content)
  end

  defp json_encode!(record), do: JSON.encode!(record)
end
