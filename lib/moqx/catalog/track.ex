defmodule MOQX.Catalog.Track do
  @moduledoc """
  A single track entry from a CMSF catalog.

  Tracks represent individual media streams (video, audio, timeline, etc.)
  discovered from a remote relay's catalog. Use the fields directly to inspect
  track metadata such as codec, role, or packaging.

  The `raw` field preserves the original JSON map for forward compatibility
  with catalog fields not yet modeled as struct keys.
  """

  defstruct [:name, :role, :packaging, :codec, :depends, :init_data, :raw]

  @type t :: %__MODULE__{
          name: String.t(),
          role: String.t() | nil,
          packaging: String.t() | nil,
          codec: String.t() | nil,
          depends: [String.t()],
          init_data: binary() | nil,
          raw: map()
        }

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
end
