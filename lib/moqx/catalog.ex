defmodule MOQX.Catalog do
  @moduledoc """
  A decoded CMSF or HANG catalog.

  CMSF preserves the Cloudflare and Moqtail initialization conventions in
  normalized `tracks` and the original `raw` map. HANG uses typed `media`
  sections keyed by `:audio`/`:video`, with rendition tracks, decoder bytes,
  container initialization and extension maps. `tracks` is a flattened view;
  HANG encoding uses `media` and `extensions`, while CMSF encoding uses `raw`.

  HANG is pinned to the specification revision in `docs/interop/hang-lite05.md`.
  Unknown codecs and containers are preserved with an explicit metadata status;
  recognition does not imply playback support. Track selection policy, timeline
  retrieval, packaging, file IO, and media decoding belong to the caller.
  """

  alias MOQX.Catalog.{Compression, Hang, Track}

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
    :raw,
    media: %{},
    extensions: %{}
  ]

  @type t :: %__MODULE__{
          format: :cloudflare | :moqtail_cmsf | :hang,
          namespace: [binary()] | nil,
          version: non_neg_integer() | nil,
          streaming_format: non_neg_integer() | nil,
          streaming_format_version: binary() | nil,
          supports_delta_updates: boolean() | nil,
          common_track_fields: map(),
          tracks: [Track.t()],
          media: %{optional(:audio | :video) => MOQX.Catalog.Media.t()},
          extensions: map(),
          raw: map()
        }

  @type decode_option ::
          {:format, :cloudflare | :moqtail_cmsf | :hang}
          | {:namespace, [binary()]}
          | {:compression, :none | :deflate}
          | {:max_bytes, pos_integer()}
          | {:max_encoded_bytes, pos_integer()}

  @doc """
  Decodes one supported catalog into protocol-neutral values.

  Select `format: :hang` explicitly; CMSF callers may use shape inference.
  Both encoded input and expanded JSON default to a 1 MiB limit. Override with
  positive `:max_encoded_bytes` and `:max_bytes`. `compression: :deflate` uses
  HANG raw DEFLATE sync-flush framing, not gzip or a zlib container.
  `:namespace` anchors relative HANG broadcast references. Above-root or
  unanchored references remain explicit address errors in the track.
  """
  @spec decode(binary(), [decode_option()]) :: {:ok, t()} | {:error, MOQX.Catalog.Error.t()}
  def decode(payload, options \\ []) when is_binary(payload) do
    with {:ok, payload} <- Compression.decode(payload, options) do
      if Keyword.get(options, :format) == :hang do
        Hang.decode(payload, options)
      else
        decode_cmsf(payload, options)
      end
    end
  end

  @doc "Encodes a typed catalog. HANG media fields and extension maps are authoritative."
  @spec encode(t(), keyword()) :: {:ok, binary()} | {:error, MOQX.Catalog.Error.t()}
  def encode(catalog, options \\ []) do
    result =
      case catalog do
        %__MODULE__{format: :hang} -> Hang.encode(catalog)
        %__MODULE__{raw: raw} -> {:ok, JSON.encode!(raw)}
      end

    with {:ok, payload} <- result, do: Compression.encode(payload, options)
  rescue
    _error in [
      ArgumentError,
      KeyError,
      BadMapError,
      Protocol.UndefinedError,
      FunctionClauseError,
      CaseClauseError
    ] ->
      {:error, %MOQX.Catalog.Error{path: [], reason: :invalid_shape}}
  end

  defp decode_cmsf(payload, options) do
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

  @doc "Builds the protocol-neutral address of one track in this catalog."
  @spec track_ref(t(), Track.t()) :: MOQX.TrackRef.t() | {:error, atom()}
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
end
