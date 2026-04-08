defmodule MOQX.Debug do
  @moduledoc """
  Debug helpers for inspecting raw MOQ frame payloads.

  This module is intentionally low-level and focused on practical diagnostics,
  especially for MP4/CMAF payloads that include a top-level `prft` box
  (Producer Reference Time).
  """

  @ntp_epoch_offset_ms 2_208_988_800_000
  @max_u32 4_294_967_296

  @typedoc "Top-level ISO BMFF box descriptor."
  @type box_info :: %{type: String.t(), size: pos_integer(), offset: non_neg_integer()}

  @typedoc "Parsed PRFT fields."
  @type prft_info :: %{
          version: 0 | 1,
          flags: non_neg_integer(),
          reference_track_id: non_neg_integer(),
          ntp_timestamp: non_neg_integer(),
          publisher_unix_ms: integer(),
          media_time: non_neg_integer()
        }

  @doc """
  Lists top-level ISO BMFF boxes in `payload`.

  Returns best-effort parsed boxes and stops when encountering malformed or
  incomplete trailing data.
  """
  @spec top_level_boxes(binary()) :: [box_info()]
  def top_level_boxes(payload) when is_binary(payload) do
    payload
    |> do_top_level_boxes(0, [])
    |> Enum.reverse()
  end

  @doc """
  Parses the first top-level `prft` box from a frame payload.

  Returns `{:ok, prft_info}` or `{:error, reason}`.
  """
  @spec parse_prft(binary()) :: {:ok, prft_info()} | {:error, String.t()}
  def parse_prft(payload) when is_binary(payload) do
    with {:ok, box} <- find_top_level_box(payload, "prft") do
      parse_prft_box(box)
    end
  end

  @doc """
  Estimates publisher age (ms) from the first top-level `prft` box.

  This computes `max(now_ms - publisher_unix_ms, 0)`.
  """
  @spec publisher_age_ms(binary(), integer()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def publisher_age_ms(payload, now_ms \\ System.system_time(:millisecond))
      when is_binary(payload) and is_integer(now_ms) do
    with {:ok, prft} <- parse_prft(payload) do
      {:ok, max(now_ms - prft.publisher_unix_ms, 0)}
    end
  end

  @doc """
  Converts a 64-bit NTP timestamp to Unix epoch milliseconds.
  """
  @spec ntp_to_unix_ms(non_neg_integer()) :: integer()
  def ntp_to_unix_ms(ntp_timestamp) when is_integer(ntp_timestamp) and ntp_timestamp >= 0 do
    upper = div(ntp_timestamp, @max_u32)
    lower = rem(ntp_timestamp, @max_u32)

    upper_ms = upper * 1000
    lower_ms = div(lower * 1000, @max_u32)

    upper_ms + lower_ms - @ntp_epoch_offset_ms
  end

  defp do_top_level_boxes(<<>>, _offset, acc), do: acc
  defp do_top_level_boxes(payload, _offset, acc) when byte_size(payload) < 8, do: acc

  defp do_top_level_boxes(payload, offset, acc) do
    case parse_box(payload) do
      {:ok, %{type: type, size: size}, rest} ->
        info = %{type: type, size: size, offset: offset}
        do_top_level_boxes(rest, offset + size, [info | acc])

      :error ->
        acc
    end
  end

  defp find_top_level_box(payload, wanted_type) do
    do_find_top_level_box(payload, wanted_type)
  end

  defp do_find_top_level_box(payload, _wanted_type) when byte_size(payload) < 8,
    do: {:error, "prft box not found"}

  defp do_find_top_level_box(payload, wanted_type) do
    case parse_box(payload) do
      {:ok, %{type: type, size: size}, rest} ->
        if type == wanted_type do
          <<box::binary-size(size), _::binary>> = payload
          {:ok, box}
        else
          do_find_top_level_box(rest, wanted_type)
        end

      :error ->
        {:error, "prft box not found"}
    end
  end

  defp parse_prft_box(
         <<_size::32, "prft", version::8, flags::24, ref_track_id::32, ntp::64, rest::binary>>
       ) do
    case version do
      0 ->
        case rest do
          <<media_time::32, _::binary>> ->
            {:ok,
             %{
               version: 0,
               flags: flags,
               reference_track_id: ref_track_id,
               ntp_timestamp: ntp,
               publisher_unix_ms: ntp_to_unix_ms(ntp),
               media_time: media_time
             }}

          _ ->
            {:error, "invalid prft payload"}
        end

      1 ->
        case rest do
          <<media_time::64, _::binary>> ->
            {:ok,
             %{
               version: 1,
               flags: flags,
               reference_track_id: ref_track_id,
               ntp_timestamp: ntp,
               publisher_unix_ms: ntp_to_unix_ms(ntp),
               media_time: media_time
             }}

          _ ->
            {:error, "invalid prft payload"}
        end

      _ ->
        {:error, "unsupported prft version: #{version}"}
    end
  end

  defp parse_prft_box(_), do: {:error, "invalid prft payload"}

  defp parse_box(payload) when byte_size(payload) < 8, do: :error

  defp parse_box(<<0::32, type::binary-size(4), _::binary>> = payload) do
    # Size 0 means box extends to EOF.
    size = byte_size(payload)
    <<_box::binary-size(size), rest::binary>> = payload
    {:ok, %{type: type, size: size}, rest}
  end

  defp parse_box(<<1::32, type::binary-size(4), ext_size::64, _::binary>> = payload) do
    if ext_size < 16 or ext_size > byte_size(payload) do
      :error
    else
      size = ext_size
      <<_box::binary-size(size), rest::binary>> = payload
      {:ok, %{type: type, size: size}, rest}
    end
  end

  defp parse_box(<<size::32, type::binary-size(4), _::binary>> = payload) do
    if size < 8 or size > byte_size(payload) do
      :error
    else
      <<_box::binary-size(size), rest::binary>> = payload
      {:ok, %{type: type, size: size}, rest}
    end
  end
end
