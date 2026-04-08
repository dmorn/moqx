defmodule MOQX.DebugTest do
  use ExUnit.Case, async: true

  alias MOQX.Debug

  @ntp_epoch_offset_ms 2_208_988_800_000
  @max_u32 4_294_967_296

  test "top_level_boxes/1 parses simple box list" do
    payload =
      prft_box(1_700_000_000_123, 4_108_000_000, 1) <> box("moof") <> box("mdat", <<1, 2, 3>>)

    assert [
             %{type: "prft", offset: 0},
             %{type: "moof", offset: o1},
             %{type: "mdat", offset: o2}
           ] = Debug.top_level_boxes(payload)

    assert o1 > 0
    assert o2 > o1
  end

  test "parse_prft/1 parses version 1 prft" do
    unix_ms = 1_700_000_000_123
    media_time = 4_108_000_000
    payload = prft_box(unix_ms, media_time, 1) <> box("moof") <> box("mdat", <<0>>)

    assert {:ok, prft} = Debug.parse_prft(payload)
    assert prft.version == 1
    assert prft.media_time == media_time
    assert abs(prft.publisher_unix_ms - unix_ms) <= 1
  end

  test "parse_prft/1 parses version 0 prft" do
    unix_ms = 1_700_000_000_500
    media_time = 123_456
    payload = prft_box(unix_ms, media_time, 0)

    assert {:ok, prft} = Debug.parse_prft(payload)
    assert prft.version == 0
    assert prft.media_time == media_time
    assert abs(prft.publisher_unix_ms - unix_ms) <= 1
  end

  test "publisher_age_ms/2 computes non-negative age" do
    unix_ms = 1_700_000_000_000
    payload = prft_box(unix_ms, 0, 1)

    assert {:ok, 500} = Debug.publisher_age_ms(payload, unix_ms + 500)
    assert {:ok, 0} = Debug.publisher_age_ms(payload, unix_ms - 100)
  end

  test "parse_prft/1 returns error when prft is missing" do
    assert {:error, "prft box not found"} = Debug.parse_prft(box("moof") <> box("mdat"))
  end

  defp box(type, body \\ <<>>) when is_binary(type) and byte_size(type) == 4 do
    size = 8 + byte_size(body)
    <<size::32, type::binary-size(4), body::binary>>
  end

  defp prft_box(unix_ms, media_time, version) do
    ntp = unix_ms_to_ntp(unix_ms)

    body =
      case version do
        0 -> <<0::8, 4::24, 1::32, ntp::64, media_time::32>>
        1 -> <<1::8, 4::24, 1::32, ntp::64, media_time::64>>
      end

    box("prft", body)
  end

  defp unix_ms_to_ntp(unix_ms) do
    ntp_ms = unix_ms + @ntp_epoch_offset_ms
    seconds = div(ntp_ms, 1000)
    fraction_ms = rem(ntp_ms, 1000)
    fraction = div(fraction_ms * @max_u32, 1000)
    seconds * @max_u32 + fraction
  end
end
