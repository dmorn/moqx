defmodule MOQX.Catalog do
  @moduledoc """
  A decoded Common Media Server Data Format catalog.

  Unknown fields remain available in `raw`, allowing deployed catalog variants
  to evolve without forcing callers back to raw JSON.
  """

  alias MOQX.Catalog.Track

  @enforce_keys [:tracks, :raw]
  defstruct [
    :format,
    :namespace,
    :version,
    :streaming_format,
    :streaming_format_version,
    :supports_delta_updates,
    :common_track_fields,
    :tracks,
    :raw
  ]

  @type t :: %__MODULE__{
          format: :cloudflare | :moqtail_cmsf,
          namespace: [binary()] | nil,
          version: non_neg_integer() | nil,
          streaming_format: non_neg_integer() | nil,
          streaming_format_version: binary() | nil,
          supports_delta_updates: boolean() | nil,
          common_track_fields: map(),
          tracks: [Track.t()],
          raw: map()
        }

  @type decode_option ::
          {:format, :cloudflare | :moqtail_cmsf}
          | {:namespace, [binary()]}

  @doc """
  Decodes one supported catalog into protocol-neutral values.

  Protocol implementations pass their expected `:format` explicitly.
  Standalone callers may omit it and use shape inference.
  """
  @spec decode(binary(), [decode_option()]) :: {:ok, t()} | {:error, MOQX.Catalog.Error.t()}
  def decode(payload, options \\ []) when is_binary(payload) do
    with {:ok, %{"tracks" => tracks} = decoded} when is_list(tracks) <- JSON.decode(payload),
         common when is_map(common) <- Map.get(decoded, "commonTrackFields", %{}),
         format = Keyword.get(options, :format) || catalog_format(decoded, tracks),
         :ok <- validate_format(format),
         :ok <- validate_version(decoded["version"]),
         namespace = Keyword.get(options, :namespace),
         {:ok, tracks} <- decode_tracks(tracks, common, format, namespace) do
      {:ok,
       %__MODULE__{
         format: format,
         namespace: namespace,
         version: decoded["version"],
         streaming_format: decoded["streamingFormat"],
         streaming_format_version: decoded["streamingFormatVersion"],
         supports_delta_updates: decoded["supportsDeltaUpdates"],
         common_track_fields: common,
         tracks: tracks,
         raw: decoded
       }}
    else
      {:ok, _decoded} ->
        {:error, %MOQX.Catalog.Error{path: [], reason: :invalid_shape}}

      {:error, %MOQX.Catalog.Error{} = error} ->
        {:error, error}

      {:error, _reason} ->
        {:error, %MOQX.Catalog.Error{path: [], reason: :invalid_json}}

      _other ->
        {:error, %MOQX.Catalog.Error{path: [], reason: :invalid_shape}}
    end
  end

  @doc "Returns H.264/AVC tracks ordered from highest to lowest advertised resolution."
  @spec h264_tracks(t()) :: [Track.t()]
  def h264_tracks(%__MODULE__{tracks: tracks}) do
    tracks
    |> Enum.filter(&avc_track?/1)
    |> Enum.sort_by(fn track ->
      {-resolution_area(track), -numeric_or_zero(track.bitrate), track.name}
    end)
  end

  @doc "Selects the highest-resolution advertised H.264/AVC track."
  @spec select_h264(t()) :: {:ok, Track.t()} | {:error, :h264_track_not_found}
  def select_h264(%__MODULE__{} = catalog) do
    case h264_tracks(catalog) do
      [track | _rest] -> {:ok, track}
      [] -> {:error, :h264_track_not_found}
    end
  end

  @doc "Builds the protocol-neutral address of one track in this catalog."
  @spec track_ref(t(), Track.t()) :: MOQX.TrackRef.t()
  def track_ref(%__MODULE__{} = catalog, %Track{} = track) do
    Track.track_ref(track, catalog.namespace)
  end

  defp decode_tracks(tracks, common, format, namespace) do
    tracks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, decoded} ->
      case Track.from_map(raw, common, format: format, namespace: namespace) do
        {:ok, track} ->
          {:cont, {:ok, [track | decoded]}}

        {:error, %MOQX.Catalog.Error{} = error} ->
          error = %{error | path: [:tracks, index | error.path]}
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp catalog_format(decoded, tracks) do
    if Map.has_key?(decoded, "streamingFormat") or
         Enum.any?(tracks, &(is_map(&1) and Map.has_key?(&1, "selectionParams"))) do
      :cloudflare
    else
      :moqtail_cmsf
    end
  end

  defp validate_version(1), do: :ok

  defp validate_version(nil) do
    {:error, %MOQX.Catalog.Error{path: [:version], reason: :required, value: nil}}
  end

  defp validate_version(version) when not is_integer(version) do
    {:error, %MOQX.Catalog.Error{path: [:version], reason: :invalid_type, value: version}}
  end

  defp validate_version(version) do
    {:error,
     %MOQX.Catalog.Error{
       path: [:version],
       reason: :unsupported,
       value: version
     }}
  end

  defp validate_format(format) when format in [:cloudflare, :moqtail_cmsf], do: :ok

  defp validate_format(format) do
    {:error, %MOQX.Catalog.Error{path: [:format], reason: :unsupported, value: format}}
  end

  defp avc_track?(%Track{codec: codec, packaging: "cmaf"} = track) when is_binary(codec),
    do:
      video_role?(track) and initializable?(track) and
        String.starts_with?(String.downcase(codec), ["avc1", "avc3"])

  defp avc_track?(%Track{codec: codec, packaging: "chunk-per-object"} = track)
       when is_binary(codec),
       do:
         video_role?(track) and initializable?(track) and
           String.starts_with?(String.downcase(codec), ["avc1", "avc3"])

  defp avc_track?(_track), do: false

  defp video_role?(%Track{role: role}), do: role in [nil, "video"]

  defp initializable?(%Track{init_data: init_data, init_track: init_track}),
    do: is_binary(init_data) or is_binary(init_track)

  defp resolution_area(%Track{width: width, height: height})
       when is_integer(width) and is_integer(height),
       do: width * height

  defp resolution_area(_track), do: 0

  defp numeric_or_zero(value) when is_number(value), do: value
  defp numeric_or_zero(_value), do: 0
end
