defmodule MOQX.Catalog do
  @moduledoc """
  A decoded Common Media Server Data Format catalog.

  Unknown fields remain available in `raw`, allowing deployed catalog variants
  to evolve without forcing callers back to raw JSON.
  """

  alias MOQX.Catalog.Track

  @enforce_keys [:tracks, :raw]
  defstruct [
    :version,
    :streaming_format,
    :streaming_format_version,
    :supports_delta_updates,
    :common_track_fields,
    :tracks,
    :raw
  ]

  @type t :: %__MODULE__{
          version: non_neg_integer() | nil,
          streaming_format: non_neg_integer() | nil,
          streaming_format_version: binary() | nil,
          supports_delta_updates: boolean() | nil,
          common_track_fields: map(),
          tracks: [Track.t()],
          raw: map()
        }

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(payload) when is_binary(payload) do
    with {:ok, %{"tracks" => tracks} = decoded} when is_list(tracks) <- JSON.decode(payload),
         common when is_map(common) <- Map.get(decoded, "commonTrackFields", %{}),
         {:ok, tracks} <- decode_tracks(tracks, common) do
      {:ok,
       %__MODULE__{
         version: decoded["version"],
         streaming_format: decoded["streamingFormat"],
         streaming_format_version: decoded["streamingFormatVersion"],
         supports_delta_updates: decoded["supportsDeltaUpdates"],
         common_track_fields: common,
         tracks: tracks,
         raw: decoded
       }}
    else
      {:ok, _decoded} -> {:error, :invalid_catalog_shape}
      {:error, _reason} -> {:error, :invalid_catalog_json}
      _other -> {:error, :invalid_catalog_shape}
    end
  end

  @doc "Returns H.264/AVC tracks ordered from highest to lowest advertised resolution."
  @spec h264_tracks(t()) :: [Track.t()]
  def h264_tracks(%__MODULE__{tracks: tracks}) do
    tracks
    |> Enum.filter(&avc_track?/1)
    |> Enum.sort_by(&resolution_area/1, :desc)
  end

  @doc "Selects the highest-resolution advertised H.264/AVC track."
  @spec select_h264(t()) :: {:ok, Track.t()} | {:error, :h264_track_not_found}
  def select_h264(%__MODULE__{} = catalog) do
    case h264_tracks(catalog) do
      [track | _rest] -> {:ok, track}
      [] -> {:error, :h264_track_not_found}
    end
  end

  defp decode_tracks(tracks, common) do
    tracks
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, decoded} ->
      case Track.from_map(raw, common) do
        {:ok, track} -> {:cont, {:ok, [track | decoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp avc_track?(%Track{codec: codec}) when is_binary(codec),
    do: String.starts_with?(String.downcase(codec), ["avc1", "avc3"])

  defp avc_track?(_track), do: false

  defp resolution_area(%Track{width: width, height: height})
       when is_integer(width) and is_integer(height),
       do: width * height

  defp resolution_area(_track), do: 0
end
