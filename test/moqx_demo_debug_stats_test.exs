defmodule MOQX.DemoDebugStatsTest do
  use ExUnit.Case, async: true

  alias MOQX.DemoDebugStats

  @ntp_epoch_offset_ms 2_208_988_800_000
  @max_u32 4_294_967_296

  test "snapshot tracks bandwidth, groups/sec and objects/sec" do
    start_ms = 1_000

    stats =
      DemoDebugStats.new(start_ms)
      |> DemoDebugStats.add_frame(10, <<1, 2, 3, 4>>, 1_100)
      |> DemoDebugStats.add_frame(10, <<5, 6>>, 1_200)
      |> DemoDebugStats.add_frame(11, <<7>>, 1_250)

    snapshot = DemoDebugStats.snapshot(stats, 2_000)

    assert snapshot.duration_ms == 1_000
    assert snapshot.bytes_per_sec == 7.0
    assert snapshot.bitrate_kbps == 0.056
    assert snapshot.groups_per_sec == 2.0
    assert snapshot.objects_per_sec == 3.0
    assert snapshot.latency == nil
  end

  test "latency aggregates from PRFT payloads only" do
    start_ms = 10_000
    frame_1_unix = 10_250
    frame_2_unix = 10_100

    stats =
      DemoDebugStats.new(start_ms)
      |> DemoDebugStats.add_frame(1, prft_box(frame_1_unix), 10_300)
      |> DemoDebugStats.add_frame(2, prft_box(frame_2_unix), 10_400)
      |> DemoDebugStats.add_frame(3, <<0, 1, 2>>, 10_500)

    snapshot = DemoDebugStats.snapshot(stats, 11_000)

    assert %{samples: 2, min_ms: 50, max_ms: max_ms, avg_ms: avg_ms} = snapshot.latency
    assert_in_delta max_ms, 300, 1
    assert_in_delta avg_ms, 175, 1

    line = DemoDebugStats.format_snapshot(snapshot)
    assert line =~ "latency=avg="
    assert line =~ "min=50ms"
    assert line =~ "n=2"
  end

  test "format_snapshot shows n/a when stream has no PRFT" do
    snapshot =
      DemoDebugStats.new(0)
      |> DemoDebugStats.add_frame(0, <<1, 2, 3>>, 10)
      |> DemoDebugStats.snapshot(1_000)

    assert DemoDebugStats.format_snapshot(snapshot) =~ "latency=n/a"
  end

  defp prft_box(unix_ms) do
    ntp = unix_ms_to_ntp(unix_ms)
    body = <<1::8, 4::24, 1::32, ntp::64, 123::64>>
    size = 8 + byte_size(body)
    <<size::32, "prft", body::binary>>
  end

  defp unix_ms_to_ntp(unix_ms) do
    ntp_ms = unix_ms + @ntp_epoch_offset_ms
    seconds = div(ntp_ms, 1000)
    fraction_ms = rem(ntp_ms, 1000)
    fraction = div(fraction_ms * @max_u32, 1000)
    seconds * @max_u32 + fraction
  end
end
