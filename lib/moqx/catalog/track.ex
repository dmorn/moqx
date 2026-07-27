defmodule MOQX.Catalog.Track do
  @moduledoc "A track advertised by a decoded CMSF catalog."

  @enforce_keys [:name, :raw]
  defstruct [
    :namespace,
    :name,
    :init_track,
    :init_data,
    :packaging,
    :role,
    :render_group,
    :alt_group,
    :codec,
    :mime_type,
    :framerate,
    :bitrate,
    :width,
    :height,
    :timescale,
    :samplerate,
    :channel_config,
    :language,
    :depends,
    :raw
  ]

  @type t :: %__MODULE__{
          name: binary(),
          raw: map(),
          namespace: binary() | [binary()] | nil,
          init_data: binary() | nil
        }

  @doc false
  def from_map(raw, common, options \\ [])

  def from_map(%{"name" => name} = raw, common, options)
      when is_binary(name) and is_map(common) do
    selection = Map.get(raw, "selectionParams", %{})
    format = Keyword.get(options, :format, :cloudflare)

    with :ok <- validate_selection(selection),
         :ok <- validate_current_fields(raw, format),
         {:ok, init_data} <- decode_init_data(raw["initData"]) do
      {:ok, build_track(raw, common, selection, options, name, init_data)}
    end
  end

  def from_map(%{"name" => name}, _common, _options) do
    catalog_error([:name], :invalid_type, name)
  end

  def from_map(%{} = raw, _common, _options) do
    catalog_error([:name], :required, Map.get(raw, "name"))
  end

  def from_map(raw, _common, _options) do
    {:error,
     %MOQX.Catalog.Error{
       path: [],
       reason: :invalid_shape,
       value: raw
     }}
  end

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

  defp selected(raw, selection, key), do: Map.get(raw, key, Map.get(selection, key))

  defp build_track(raw, common, selection, options, name, init_data) do
    %__MODULE__{
      namespace: inherited(raw, common, "namespace") || Keyword.get(options, :namespace),
      name: name,
      init_track: raw["initTrack"],
      init_data: init_data,
      packaging: inherited(raw, common, "packaging"),
      role: inherited(raw, common, "role"),
      render_group: inherited(raw, common, "renderGroup"),
      alt_group: inherited(raw, common, "altGroup"),
      codec: selected(raw, selection, "codec"),
      mime_type: selected(raw, selection, "mimeType"),
      framerate: selected(raw, selection, "framerate"),
      bitrate: selected(raw, selection, "bitrate"),
      width: selected(raw, selection, "width"),
      height: selected(raw, selection, "height"),
      timescale: selected(raw, selection, "timescale"),
      samplerate: selected(raw, selection, "samplerate"),
      channel_config: selected(raw, selection, "channelConfig"),
      language: selected(raw, selection, "lang"),
      depends: Map.get(raw, "depends", []),
      raw: raw
    }
  end

  defp namespace_components(namespace) when is_list(namespace), do: namespace

  defp namespace_components(namespace) when is_binary(namespace) do
    namespace
    |> String.split("/", trim: true)
    |> case do
      [] -> [namespace]
      components -> components
    end
  end

  defp decode_init_data(nil), do: {:ok, nil}

  defp decode_init_data(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} ->
        {:ok, bytes}

      :error ->
        {:error,
         %MOQX.Catalog.Error{
           path: [:init_data],
           reason: :invalid_base64,
           value: value
         }}
    end
  end

  defp decode_init_data(value) do
    {:error,
     %MOQX.Catalog.Error{
       path: [:init_data],
       reason: :invalid_type,
       value: value
     }}
  end

  defp validate_current_fields(_raw, :cloudflare), do: :ok

  defp validate_current_fields(raw, :moqtail_cmsf) do
    with :ok <- validate_member(raw, "packaging", ["cmaf", "chunk-per-object", "timeline"]),
         :ok <- validate_member(raw, "role", ["video", "audio", "timeline"]),
         :ok <- validate_codec(raw),
         :ok <- validate_optional_number(raw, "width", &positive_number?/1),
         :ok <- validate_optional_number(raw, "height", &positive_number?/1),
         :ok <- validate_optional_number(raw, "timescale", &positive_number?/1),
         :ok <- validate_optional_number(raw, "bitrate", &non_negative_number?/1) do
      validate_optional_number(raw, "framerate", &positive_number?/1)
    end
  end

  defp validate_selection(selection) when is_map(selection), do: :ok

  defp validate_selection(selection) do
    catalog_error([:selection_params], :invalid_type, selection)
  end

  defp validate_member(raw, key, allowed) do
    case Map.fetch(raw, key) do
      :error ->
        catalog_error([field_name(key)], :required, nil)

      {:ok, value} ->
        if value in allowed do
          :ok
        else
          catalog_error([field_name(key)], :unsupported, value)
        end
    end
  end

  defp validate_codec(%{"packaging" => packaging} = raw)
       when packaging in ["cmaf", "chunk-per-object"] do
    case Map.fetch(raw, "codec") do
      {:ok, codec} when is_binary(codec) and codec != "" -> :ok
      :error -> catalog_error([:codec], :required, nil)
      {:ok, codec} -> catalog_error([:codec], :invalid_type, codec)
    end
  end

  defp validate_codec(_raw), do: :ok

  defp validate_optional_number(raw, key, range?) do
    case Map.fetch(raw, key) do
      :error ->
        :ok

      {:ok, value} when not is_number(value) ->
        catalog_error([field_name(key)], :invalid_type, value)

      {:ok, value} ->
        if range?.(value) do
          :ok
        else
          catalog_error([field_name(key)], :out_of_range, value)
        end
    end
  end

  defp positive_number?(value), do: value > 0
  defp non_negative_number?(value), do: value >= 0

  defp catalog_error(path, reason, value) do
    {:error, %MOQX.Catalog.Error{path: path, reason: reason, value: value}}
  end

  defp field_name("packaging"), do: :packaging
  defp field_name("role"), do: :role
  defp field_name("width"), do: :width
  defp field_name("height"), do: :height
  defp field_name("timescale"), do: :timescale
  defp field_name("bitrate"), do: :bitrate
  defp field_name("framerate"), do: :framerate
end
