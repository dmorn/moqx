defmodule MOQX.Catalog.Track do
  @moduledoc """
  A single track entry from a CMSF catalog.

  Tracks represent individual media streams (video, audio, timeline, etc.)
  discovered from a remote relay's catalog. Use the fields directly to inspect
  track metadata such as codec, role, or packaging.

  The `raw` field preserves the original JSON map for forward compatibility
  with catalog fields not yet modeled as struct keys.

  Beyond raw access, this module also provides:

  - `explicit_metadata/1` for normalized, explicitly signaled metadata
  - `extra_metadata/1` for unknown extension keys from `raw`
  - `inferred_metadata/1` for best-effort derived hints (e.g. container)
  - `describe/1` to combine all three views
  """

  alias MOQX.Debug

  defstruct [:name, :role, :packaging, :codec, :depends, :init_data, :raw]

  @known_raw_keys [
    "name",
    "role",
    "packaging",
    "codec",
    "depends",
    "initData",
    "bitrate",
    "width",
    "height",
    "codedWidth",
    "codedHeight",
    "framerate",
    "sampleRate",
    "numberOfChannels",
    "timescale",
    "container",
    "description",
    "hangSection",
    "hangSectionMetadata",
    "altGroup",
    "renderGroup",
    "isLive"
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          role: String.t() | nil,
          packaging: String.t() | nil,
          codec: String.t() | nil,
          depends: [String.t()],
          init_data: binary() | nil,
          raw: map()
        }

  @type inferred_container :: :cmaf | :fmp4 | nil

  @doc false
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{"name" => name} = map) when is_binary(name) do
    init_data =
      case Map.get(map, "initData") do
        nil -> nil
        data when is_binary(data) -> Base.decode64!(data)
      end

    {:ok,
     %__MODULE__{
       name: name,
       role: map["role"],
       packaging: map["packaging"],
       codec: map["codec"],
       depends: Map.get(map, "depends", []),
       init_data: init_data,
       raw: map
     }}
  rescue
    ArgumentError -> {:error, "invalid base64 in initData for track #{inspect(map["name"])}"}
  end

  def from_map(%{"name" => name}) do
    {:error, "track name must be a string, got: #{inspect(name)}"}
  end

  def from_map(_map) do
    {:error, "track entry missing required \"name\" field"}
  end

  @doc """
  Returns normalized metadata explicitly signaled by the catalog for this track.

  Fields absent from the catalog are omitted from the returned map.
  """
  @spec explicit_metadata(t()) :: map()
  def explicit_metadata(%__MODULE__{} = track) do
    %{
      name: track.name,
      role: track.role,
      codec: track.codec,
      packaging: track.packaging,
      depends: track.depends,
      init_data_present: not is_nil(track.init_data),
      bitrate: track.raw["bitrate"],
      width: track.raw["width"],
      height: track.raw["height"],
      coded_width: track.raw["codedWidth"],
      coded_height: track.raw["codedHeight"],
      framerate: track.raw["framerate"],
      sample_rate: track.raw["sampleRate"],
      number_of_channels: track.raw["numberOfChannels"],
      timescale: track.raw["timescale"],
      container: track.raw["container"],
      description: track.raw["description"],
      hang_section: track.raw["hangSection"],
      alt_group: track.raw["altGroup"],
      render_group: track.raw["renderGroup"],
      is_live: track.raw["isLive"]
    }
    |> compact_map()
  end

  @doc """
  Returns raw catalog keys not currently modeled as known metadata fields.
  """
  @spec extra_metadata(t()) :: map()
  def extra_metadata(%__MODULE__{raw: raw}) do
    Map.drop(raw, @known_raw_keys)
  end

  @doc """
  Returns best-effort inferred metadata derived from explicit fields.

  This does not replace explicit catalog signaling. It adds practical hints,
  such as inferred container type.
  """
  @spec inferred_metadata(t()) :: map()
  def inferred_metadata(%__MODULE__{} = track) do
    {container, source} = infer_container(track)

    %{
      container: container,
      container_source: source,
      init_data_major_brand: init_data_major_brand(track.init_data)
    }
    |> compact_map()
  end

  @doc """
  Returns `%{explicit: ..., inferred: ..., extra: ...}` for one track.
  """
  @spec describe(t()) :: %{explicit: map(), inferred: map(), extra: map()}
  def describe(%__MODULE__{} = track) do
    %{
      explicit: explicit_metadata(track),
      inferred: inferred_metadata(track),
      extra: extra_metadata(track)
    }
  end

  defp infer_container(%__MODULE__{} = track) do
    case infer_container_from_init_data(track.init_data) do
      {:ok, container} -> {container, :init_data}
      :error -> infer_container_from_packaging(track.packaging)
    end
  end

  defp infer_container_from_init_data(nil), do: :error

  defp infer_container_from_init_data(init_data) when is_binary(init_data) do
    box_types = init_data |> Debug.top_level_boxes() |> Enum.map(& &1.type)

    cond do
      "ftyp" in box_types and "moov" in box_types ->
        case init_data_major_brand(init_data) do
          brand when brand in ["cmf2", "cmfc", "cmfa", "cmfs", "cmfv"] -> {:ok, :cmaf}
          _ -> {:ok, :fmp4}
        end

      "ftyp" in box_types ->
        {:ok, :fmp4}

      true ->
        :error
    end
  end

  defp infer_container_from_packaging("cmaf"), do: {:cmaf, :packaging}
  defp infer_container_from_packaging("legacy"), do: {:legacy, :packaging}
  defp infer_container_from_packaging(_), do: {nil, :unknown}

  defp init_data_major_brand(nil), do: nil

  defp init_data_major_brand(<<size::32, "ftyp", major_brand::binary-size(4), _::binary>> = data)
       when size >= 16 and size <= byte_size(data),
       do: major_brand

  defp init_data_major_brand(_), do: nil

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
