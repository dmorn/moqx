defmodule MOQXProbe.BenchCliTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.expand("../../bench/stream_clients.exs", __DIR__))
  Code.require_file(Path.expand("../../bench/datagram_clients.exs", __DIR__))

  alias MOQXProbe.Bench.DatagramClients
  alias MOQXProbe.Bench.StreamClients

  test "stream client CLI keeps repeated matrix and preflight flags" do
    options =
      StreamClients.parse_cli!([
        "--input",
        "flow-generated",
        "--input",
        "flow-prebuilt-list",
        "--implementation",
        "context_owner",
        "--implementation",
        "stream_owner",
        "--implementation",
        "sender_shards",
        "--git-sha",
        "test-sha",
        "--iperf-preflight-summary",
        "/tmp/tcp.json",
        "--iperf-preflight-summary",
        "/tmp/udp.json"
      ])

    assert options.inputs == ["flow-generated", "flow-prebuilt-list"]
    assert options.implementations == ["context_owner", "stream_owner", "sender_shards"]

    assert Enum.map(options.base.iperf3_preflight, & &1.path) == [
             "/tmp/tcp.json",
             "/tmp/udp.json"
           ]
  end

  test "context-owned stream client reports compact local sender diagnostics" do
    input = stream_client_input("context_owner")

    assert %{
             implementation: "context_owner",
             accepted: 6,
             completed: 6,
             errors: 0,
             stop_reason: "complete",
             pacer: %{tick_count: tick_count},
             bursts: %{count: burst_count},
             tick_send_count: %{max: max_tick_send_count}
           } = StreamClients.run_context_owner(input)

    assert tick_count > 0
    assert burst_count > 0
    assert max_tick_send_count > 0
  end

  test "stream-owned stream client is flow-fed and reports shard diagnostics" do
    input = stream_client_input("stream_owner")

    assert %{
             implementation: "stream_owner",
             accepted: 6,
             completed: 6,
             in_flight: 0,
             configured_shard_count: 2,
             active_shard_count: 2,
             streams_per_shard: %{max: 1},
             send_calls: 6,
             payload_events: 6,
             completion_events: 6,
             dispatcher: %{routed_events: 6, unknown_stream_events: 0},
             shard_duration_us: %{count: 2},
             receive_calls: %{count: 2, total: receive_call_count},
             schedule_rounds: %{count: 2, total: schedule_round_count}
           } = StreamClients.run_stream_owner(input)

    assert receive_call_count > 0
    assert schedule_round_count > 0
  end

  test "sender-shards stream client routes flow input across configured shards" do
    input = stream_client_input("sender_shards") |> Map.put(:sender_shard_count, 1)

    assert %{
             implementation: "sender_shards",
             accepted: 6,
             completed: 6,
             configured_shard_count: 1,
             active_shard_count: 1,
             streams_per_shard: %{max: 2},
             send_calls: 6,
             payload_events: 6,
             completion_events: 6,
             dispatcher: %{routed_events: 6, unknown_stream_events: 0}
           } = StreamClients.run_sender_shards(input)
  end

  test "datagram client CLI keeps repeated send flags and preflight flags" do
    options =
      DatagramClients.parse_cli!([
        "--datagram-send-flag",
        "dgram_priority",
        "--datagram-send-flag",
        "cancel_on_blocked",
        "--git-sha",
        "test-sha",
        "--iperf-preflight-summary",
        "/tmp/tcp.json",
        "--iperf-preflight-summary",
        "/tmp/udp.json"
      ])

    assert options.base.datagram_send_flags == [:dgram_priority, :cancel_on_blocked]

    assert Enum.map(options.base.iperf3_preflight, & &1.path) == [
             "/tmp/tcp.json",
             "/tmp/udp.json"
           ]
  end

  defp stream_client_input(implementation) do
    options =
      StreamClients.parse_cli!([
        "--input",
        "flow-generated",
        "--implementation",
        implementation,
        "--stream-count",
        "2",
        "--payload-count",
        "3",
        "--payload-size",
        "8",
        "--stream-send-window",
        "1",
        "--event-batch-size",
        "8",
        "--max-burst",
        "4",
        "--timeout-ms",
        "1000",
        "--git-sha",
        "test-sha"
      ])

    options
    |> StreamClients.inputs()
    |> Map.fetch!("flow-generated")
    |> Map.put(:implementation, implementation)
  end
end
