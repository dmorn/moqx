defmodule MOQX.Catalog do
  @moduledoc """
  Decodes CMSF catalog payloads and provides track discovery helpers.

  A CMSF catalog is a UTF-8 JSON payload retrieved via `MOQX.Helpers.fetch_catalog/2`.
  This module parses those raw bytes into an inspectable Elixir structure.

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

  defstruct [:version, :supports_delta_updates, :tracks, :raw]

  @type t :: %__MODULE__{
          version: integer() | nil,
          supports_delta_updates: boolean() | nil,
          tracks: [Track.t()],
          raw: map()
        }

  @doc """
  Decodes a raw CMSF catalog binary into a `%MOQX.Catalog{}`.

  Accepts the raw bytes delivered by `{:moqx_fetch_object, ...}` messages.
  Returns `{:ok, catalog}` on success or `{:error, reason}` on failure.

  ## Example

      {:ok, catalog} = MOQX.Catalog.decode(payload)
      MOQX.Catalog.video_tracks(catalog)
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, String.t()}
  def decode(binary) when is_binary(binary) do
    with {:ok, map} <- json_decode(binary),
         :ok <- validate_shape(map),
         {:ok, tracks} <- parse_tracks(map["tracks"]) do
      {:ok,
       %__MODULE__{
         version: map["version"],
         supports_delta_updates: map["supportsDeltaUpdates"],
         tracks: tracks,
         raw: map
       }}
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
end
