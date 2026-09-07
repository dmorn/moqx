defmodule MOQX.Catalog.HangValidation do
  @moduledoc false
  @max_integer 9_007_199_254_740_991

  def validate(raw) when is_map(raw) do
    each([{:audio, "audio"}, {:video, "video"}], fn {kind, key} ->
      if Map.has_key?(raw, key), do: section(raw[key], kind), else: :ok
    end)
  end

  def validate(_raw), do: error([], :invalid_shape)

  defp section(raw, kind) when is_map(raw) do
    with :ok <- field(raw, "renditions", [kind], &is_map/1, true),
         :ok <- field(raw, "rotation", [kind], &is_number/1),
         :ok <- field(raw, "flip", [kind], &is_boolean/1),
         :ok <- display(raw["display"], [kind, :display]) do
      raw["renditions"] |> Enum.sort() |> Enum.with_index() |> each(&named_rendition(&1, kind))
    end
  end

  defp section(_raw, kind), do: error([kind], :invalid_shape)

  defp named_rendition({{name, config}, index}, kind) do
    path = [kind, :renditions, index]

    if is_binary(name) and name != "",
      do: rendition(config, kind, path),
      else: error(path, :invalid_type)
  end

  defp rendition(raw, kind, path) when is_map(raw) do
    with :ok <- field(raw, "codec", path, &nonempty?/1, true),
         :ok <-
           binary_field(raw, "description", path, &Base.decode16(&1, case: :mixed), :invalid_hex),
         :ok <- container(Map.get(raw, "container", %{"kind" => "legacy"}), path ++ [:container]),
         :ok <- timeline(raw["timeline"], path ++ [:timeline]),
         :ok <- field(raw, "broadcast", path, &relative_path?/1),
         :ok <- field(raw, "stalled", path, &is_boolean/1),
         :ok <- field(raw, "optimizeForLatency", path, &is_boolean/1),
         :ok <- field(raw, "jitter", path, &(is_number(&1) and &1 >= 0)),
         :ok <- field(raw, "framerate", path, &(is_number(&1) and &1 > 0)),
         :ok <-
           each(
             [
               "codedWidth",
               "codedHeight",
               "displayAspectWidth",
               "displayAspectHeight",
               "bitrate"
             ],
             &field(raw, &1, path, fn n -> integer?(n, 0) end)
           ) do
      audio(raw, kind, path)
    end
  end

  defp rendition(_raw, _kind, path), do: error(path, :invalid_shape)

  defp audio(_raw, :video, _path), do: :ok

  defp audio(raw, :audio, path) do
    with :ok <- field(raw, "sampleRate", path, &integer?(&1, 1), true),
         :ok <- field(raw, "numberOfChannels", path, &integer?(&1, 1), true) do
      if raw["codec"] == "pcm" and
           (Map.has_key?(raw, "description") or
              (Map.has_key?(raw, "bitrate") and
                 raw["bitrate"] != raw["sampleRate"] * raw["numberOfChannels"] * 32)),
         do: error(path, :invalid_pcm),
         else: :ok
    end
  end

  defp container(raw, path) when is_map(raw) do
    with :ok <- field(raw, "kind", path, &nonempty?/1, true) do
      container_init(raw, path)
    end
  end

  defp container(_raw, path), do: error(path, :invalid_shape)

  defp container_init(%{"kind" => "cmaf"} = raw, path) do
    with :ok <- field(raw, "init", path, &is_binary/1, true),
         do: binary_field(raw, "init", path, &Base.decode64/1, :invalid_base64)
  end

  defp container_init(_raw, _path), do: :ok

  defp timeline(nil, _path), do: :ok

  defp timeline(raw, path) when is_map(raw) do
    with :ok <- field(raw, "track", path, &nonempty?/1, true),
         :ok <- field(raw, "timescale", path, &integer?(&1, 1)),
         do: field(raw, "wall", path, &integer?(&1, 0))
  end

  defp timeline(_raw, path), do: error(path, :invalid_shape)

  defp display(nil, _path), do: :ok

  defp display(raw, path) when is_map(raw) do
    with :ok <- field(raw, "width", path, &integer?(&1, 1), true),
         do: field(raw, "height", path, &integer?(&1, 1), true)
  end

  defp display(_raw, path), do: error(path, :invalid_shape)

  defp field(raw, key, path, valid?, required? \\ false) do
    case Map.fetch(raw, key) do
      :error when not required? ->
        :ok

      :error ->
        error(path ++ [field_name(key)], :required)

      {:ok, value} ->
        if valid?.(value), do: :ok, else: error(path ++ [field_name(key)], :invalid_type)
    end
  end

  defp binary_field(raw, key, path, decode, reason) do
    case Map.fetch(raw, key) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        case decode.(value) do
          {:ok, _bytes} -> :ok
          :error -> error(path ++ [field_name(key)], reason)
        end

      _ ->
        error(path ++ [field_name(key)], :invalid_type)
    end
  end

  defp each(values, fun),
    do:
      Enum.reduce_while(values, :ok, fn value, :ok ->
        case fun.(value) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp integer?(n, min), do: is_integer(n) and n >= min and n <= @max_integer
  defp nonempty?(value), do: is_binary(value) and value != ""

  defp relative_path?(value) when is_binary(value) do
    not String.starts_with?(value, "/") and not String.contains?(value, [":", "?", "#", "\\"])
  end

  defp relative_path?(_value), do: false

  defp error(path, reason), do: {:error, %MOQX.Catalog.Error{path: path, reason: reason}}

  # Only statically known field names become atoms; peer-provided names never do.
  for key <-
        ~w(renditions rotation flip codec description kind init track timescale wall width height broadcast stalled optimizeForLatency framerate codedWidth codedHeight displayAspectWidth displayAspectHeight bitrate jitter sampleRate numberOfChannels) do
    defp field_name(unquote(key)), do: unquote(String.to_atom(key))
  end
end
