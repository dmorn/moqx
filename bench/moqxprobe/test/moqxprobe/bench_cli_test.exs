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
        "--git-sha",
        "test-sha",
        "--iperf-preflight-summary",
        "/tmp/tcp.json",
        "--iperf-preflight-summary",
        "/tmp/udp.json"
      ])

    assert options.inputs == ["flow-generated", "flow-prebuilt-list"]
    assert options.implementations == ["context_owner", "stream_owner"]

    assert Enum.map(options.base.iperf3_preflight, & &1.path) == [
             "/tmp/tcp.json",
             "/tmp/udp.json"
           ]
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
end
