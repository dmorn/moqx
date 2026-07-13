defmodule MOQX.Catalog.Track do
  @moduledoc "A track advertised by a decoded CMSF catalog."

  @enforce_keys [:name, :raw]
  defstruct [
    :namespace,
    :name,
    :init_track,
    :init_data,
    :packaging,
    :render_group,
    :alt_group,
    :codec,
    :mime_type,
    :framerate,
    :bitrate,
    :width,
    :height,
    :samplerate,
    :channel_config,
    :language,
    :depends,
    :raw
  ]

  @type t :: %__MODULE__{name: binary(), raw: map(), namespace: binary() | nil}

  @doc false
  def from_map(%{"name" => name} = raw, common) when is_binary(name) and is_map(common) do
    selection = Map.get(raw, "selectionParams", %{})

    if is_map(selection) do
      {:ok,
       %__MODULE__{
         namespace: inherited(raw, common, "namespace"),
         name: name,
         init_track: raw["initTrack"],
         init_data: raw["initData"],
         packaging: inherited(raw, common, "packaging"),
         render_group: inherited(raw, common, "renderGroup"),
         alt_group: inherited(raw, common, "altGroup"),
         codec: selection["codec"],
         mime_type: selection["mimeType"],
         framerate: selection["framerate"],
         bitrate: selection["bitrate"],
         width: selection["width"],
         height: selection["height"],
         samplerate: selection["samplerate"],
         channel_config: selection["channelConfig"],
         language: selection["lang"],
         depends: Map.get(raw, "depends", []),
         raw: raw
       }}
    else
      {:error, :invalid_selection_params}
    end
  end

  def from_map(_raw, _common), do: {:error, :invalid_catalog_track}

  @doc "Builds the protocol-neutral address advertised by this catalog track."
  @spec track_ref(t(), binary() | nil) :: MOQX.TrackRef.t()
  def track_ref(%__MODULE__{} = track, fallback_namespace \\ nil) do
    namespace = track.namespace || fallback_namespace || ""

    %MOQX.TrackRef{
      namespace: namespace_components(namespace),
      track: track.name
    }
  end

  defp inherited(raw, common, key), do: Map.get(raw, key, Map.get(common, key))

  defp namespace_components(namespace) do
    namespace
    |> String.split("/", trim: true)
    |> case do
      [] -> [namespace]
      components -> components
    end
  end
end
