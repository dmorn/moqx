defmodule MOQX.Catalog do
  @moduledoc """
  Decodes supported catalog payloads and provides track discovery helpers.

  Catalogs are UTF-8 JSON payloads retrieved via `MOQX.Helpers.fetch_catalog/2`
  or live subscription. This module parses those raw bytes into an inspectable
  Elixir structure.

  Supported catalog dialects:

  - CMSF-style catalogs with a top-level `"tracks"` list.
  - HANG catalogs published on `catalog.json`, with WebCodecs-shaped
    `"audio"`/`"video"` rendition maps and named extension tracks such as chat
    or location.

  ## Example

      {:ok, ref} = MOQX.Helpers.fetch_catalog(subscriber, namespace: "moqtail")
      {:ok, catalog} = MOQX.Helpers.await_catalog(ref, 5_000)

      catalog
      |> MOQX.Catalog.video_tracks()
      |> Enum.map(& &1.name)
      #=> ["259", "260", "261"]

  The `raw` field on both `MOQX.Catalog` and `MOQX.Catalog.Track` preserves
  the original JSON map for forward compatibility with fields not yet modeled
  as struct keys.
  """

  alias MOQX.Catalog.Track

  defstruct [:format, :version, :supports_delta_updates, :tracks, :raw]

  @type t :: %__MODULE__{
          version: integer() | nil,
          format: :cmsf | :hang,
          supports_delta_updates: boolean() | nil,
          tracks: [Track.t()],
          raw: map()
        }

  @doc """
  Decodes a raw catalog binary into a `%MOQX.Catalog{}`.

  Accepts the raw bytes delivered by `{:moqx_fetch_object, ...}` messages.
  Returns `{:ok, catalog}` on success or `{:error, reason}` on failure.

  ## Example

      {:ok, catalog} = MOQX.Catalog.decode(payload)
      MOQX.Catalog.video_tracks(catalog)
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, String.t()}
  def decode(binary) when is_binary(binary) do
    with {:ok, map} <- json_decode(binary) do
      parse_catalog(map)
    end
  end

  @doc """
  Bang variant of `decode/1`. Raises on invalid input.
  """
  @spec decode!(binary()) :: t()
  def decode!(binary) do
    case decode(binary) do
      {:ok, catalog} -> catalog
      {:error, reason} -> raise ArgumentError, "failed to decode CMSF catalog: #{reason}"
    end
  end

  @doc """
  Returns all tracks in the catalog.
  """
  @spec tracks(t()) :: [Track.t()]
  def tracks(%__MODULE__{tracks: tracks}), do: tracks

  @doc """
  Finds a track by exact name. Returns `nil` if not found.
  """
  @spec get_track(t(), String.t()) :: Track.t() | nil
  def get_track(%__MODULE__{tracks: tracks}, name) when is_binary(name) do
    Enum.find(tracks, &(&1.name == name))
  end

  @doc """
  Returns tracks matching the given role string (e.g. `"video"`, `"audio"`).
  """
  @spec tracks_by_role(t(), String.t()) :: [Track.t()]
  def tracks_by_role(%__MODULE__{tracks: tracks}, role) when is_binary(role) do
    Enum.filter(tracks, &(&1.role == role))
  end

  @doc """
  Returns all video tracks.
  """
  @spec video_tracks(t()) :: [Track.t()]
  def video_tracks(catalog), do: tracks_by_role(catalog, "video")

  @doc """
  Returns all audio tracks.
  """
  @spec audio_tracks(t()) :: [Track.t()]
  def audio_tracks(catalog), do: tracks_by_role(catalog, "audio")

  # -- Private ----------------------------------------------------------------

  defp json_decode(binary) do
    case JSON.decode(binary) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, "expected a JSON object at the top level"}
      {:error, _} -> {:error, "invalid JSON"}
    end
  end

  defp validate_shape(%{"tracks" => tracks}) when is_list(tracks), do: :ok
  defp validate_shape(%{"tracks" => _}), do: {:error, "\"tracks\" must be a list"}
  defp validate_shape(_), do: {:error, "missing required \"tracks\" key"}

  defp parse_catalog(%{"tracks" => _tracks} = map) do
    with :ok <- validate_shape(map),
         {:ok, tracks} <- parse_tracks(map["tracks"]) do
      {:ok,
       %__MODULE__{
         format: :cmsf,
         version: map["version"],
         supports_delta_updates: map["supportsDeltaUpdates"],
         tracks: tracks,
         raw: map
       }}
    end
  end

  defp parse_catalog(map) do
    tracks =
      []
      |> add_hang_media_tracks(map, "video")
      |> add_hang_media_tracks(map, "audio")
      |> add_hang_named_track(map, ["chat", "message"], "chat.message")
      |> add_hang_named_track(map, ["chat", "typing"], "chat.typing")
      |> add_hang_named_track(map, ["location", "track"], "location")
      |> add_hang_named_track(map, ["location", "peers"], "location.peers")
      |> add_hang_named_track(map, ["preview"], "preview")
      |> Enum.reverse()

    if tracks == [] and not hang_catalog?(map) do
      validate_shape(map)
    else
      {:ok,
       %__MODULE__{
         format: :hang,
         version: nil,
         supports_delta_updates: nil,
         tracks: tracks,
         raw: map
       }}
    end
  end

  defp parse_tracks(raw_tracks) do
    raw_tracks
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case Track.from_map(raw) do
        {:ok, track} -> {:cont, {:ok, [track | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, tracks} -> {:ok, Enum.reverse(tracks)}
      error -> error
    end
  end

  defp hang_catalog?(map) do
    Enum.any?(
      ["audio", "video", "chat", "location", "user", "capabilities", "preview"],
      &Map.has_key?(map, &1)
    )
  end

  defp add_hang_media_tracks(acc, map, role) do
    case get_in(map, [role, "renditions"]) do
      renditions when is_map(renditions) ->
        common = Map.drop(Map.get(map, role, %{}), ["renditions"])
        Enum.reduce(renditions, acc, &add_hang_rendition(&1, &2, role, common))

      _ ->
        acc
    end
  end

  defp add_hang_rendition({name, config}, acc, role, common)
       when is_binary(name) and is_map(config) do
    raw =
      config
      |> Map.merge(%{
        "name" => name,
        "role" => role,
        "hangSection" => role,
        "hangSectionMetadata" => common
      })
      |> maybe_put_hang_packaging()

    case Track.from_map(raw) do
      {:ok, track} -> [track | acc]
      {:error, _} -> acc
    end
  end

  defp add_hang_rendition(_, acc, _, _), do: acc

  defp add_hang_named_track(acc, map, path, role) do
    case get_in(map, path) do
      %{"name" => name} = track when is_binary(name) ->
        raw =
          Map.merge(track, %{
            "role" => role,
            "hangSection" => Enum.join(path, ".")
          })

        case Track.from_map(raw) do
          {:ok, parsed} -> [parsed | acc]
          {:error, _} -> acc
        end

      _ ->
        acc
    end
  end

  defp maybe_put_hang_packaging(%{"container" => %{"kind" => kind}} = raw) when is_binary(kind),
    do: Map.put(raw, "packaging", kind)

  defp maybe_put_hang_packaging(%{"container" => kind} = raw) when is_binary(kind),
    do: Map.put(raw, "packaging", kind)

  defp maybe_put_hang_packaging(raw), do: Map.put_new(raw, "packaging", "legacy")
end
