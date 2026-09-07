defmodule MOQX.Catalog.Hang do
  @moduledoc false
  alias MOQX.Catalog.{Broadcast, Container, Decoder, HangValidation, Media, Track}

  @decoder_fields [
    codec: "codec",
    description: "description",
    coded_width: "codedWidth",
    coded_height: "codedHeight",
    display_aspect_width: "displayAspectWidth",
    display_aspect_height: "displayAspectHeight",
    sample_rate: "sampleRate",
    number_of_channels: "numberOfChannels",
    optimize_for_latency: "optimizeForLatency"
  ]
  @track_fields [
    broadcast: "broadcast",
    bitrate: "bitrate",
    framerate: "framerate",
    jitter: "jitter",
    stalled: "stalled",
    timeline: "timeline"
  ]

  def decode(payload, options) do
    with {:ok, raw} when is_map(raw) <- JSON.decode(payload),
         :ok <- HangValidation.validate(raw) do
      namespace = Keyword.get(options, :namespace)

      media =
        Map.new(
          for {kind, key} <- [audio: "audio", video: "video"],
              Map.has_key?(raw, key),
              do: {kind, media(raw[key], kind, namespace)}
        )

      tracks =
        for {_kind, section} <- Enum.sort(media),
            {_name, track} <- Enum.sort(section.renditions),
            do: track

      {:ok,
       %MOQX.Catalog{
         format: :hang,
         namespace: namespace,
         tracks: tracks,
         media: media,
         extensions: Map.drop(raw, ["audio", "video"]),
         raw: raw
       }}
    else
      {:error, %MOQX.Catalog.Error{}} = error -> error
      _ -> {:error, %MOQX.Catalog.Error{path: [], reason: :invalid_json}}
    end
  end

  def encode(catalog) do
    raw =
      Enum.reduce(catalog.media, catalog.extensions, fn {kind, section}, raw ->
        Map.put(raw, Atom.to_string(kind), encode_media(section))
      end)

    with :ok <- HangValidation.validate(raw), do: {:ok, JSON.encode!(raw)}
  end

  defp media(raw, kind, namespace) do
    renditions =
      Map.new(raw["renditions"], fn {name, config} ->
        {name, track(name, config, kind, namespace)}
      end)

    %Media{
      renditions: renditions,
      display: raw["display"],
      rotation: raw["rotation"],
      flip: raw["flip"],
      extensions: Map.drop(raw, ["renditions", "display", "rotation", "flip"])
    }
  end

  defp track(name, raw, kind, namespace) do
    decoder = struct!(Decoder, Map.new(@decoder_fields, fn {field, key} -> {field, raw[key]} end))

    decoder = %{
      decoder
      | description:
          if(is_binary(decoder.description),
            do: Base.decode16!(decoder.description, case: :mixed)
          )
    }

    container = Map.get(raw, "container", %{"kind" => "legacy"})
    known_container? = container["kind"] in ["legacy", "loc", "cmaf"]

    container = %Container{
      kind: container["kind"],
      init: if(container["kind"] == "cmaf", do: Base.decode64!(container["init"])),
      extensions:
        Map.drop(container, if(container["kind"] == "cmaf", do: ["kind", "init"], else: ["kind"]))
    }

    {namespace, address_error} =
      case Broadcast.resolve(namespace, raw["broadcast"]) do
        {:ok, resolved} -> {resolved, nil}
        {:error, error} -> {nil, error}
      end

    metadata_status =
      cond do
        not known_container? -> :unknown_container
        recognized_codec?(decoder.codec) -> :recognized
        true -> :unknown_codec
      end

    fields = Map.new(@track_fields, fn {field, key} -> {field, raw[key]} end)

    struct!(
      Track,
      Map.merge(fields, %{
        name: name,
        raw: raw,
        namespace: namespace,
        role: Atom.to_string(kind),
        codec: decoder.codec,
        decoder: decoder,
        container: container,
        metadata_status: metadata_status,
        address_error: address_error,
        extensions:
          Map.drop(raw, [
            "container" | Keyword.values(@decoder_fields) ++ Keyword.values(@track_fields)
          ])
      })
    )
  end

  defp encode_media(%Media{} = section) do
    section.extensions
    |> Map.put(
      "renditions",
      Map.new(section.renditions, fn {name, track} -> {name, encode_track(track)} end)
    )
    |> put_optional("display", section.display)
    |> put_optional("rotation", section.rotation)
    |> put_optional("flip", section.flip)
  end

  defp encode_track(%Track{decoder: %Decoder{}, container: %Container{}} = track) do
    decoder =
      Enum.reduce(@decoder_fields, track.extensions, fn {field, key}, raw ->
        value = Map.fetch!(track.decoder, field)

        value =
          if field == :description and is_binary(value),
            do: Base.encode16(value, case: :lower),
            else: value

        put_optional(raw, key, value)
      end)

    container =
      track.container.extensions
      |> Map.put("kind", track.container.kind)
      |> put_optional(
        "init",
        if(is_binary(track.container.init), do: Base.encode64(track.container.init))
      )

    Enum.reduce(@track_fields, Map.put(decoder, "container", container), fn {field, key}, raw ->
      put_optional(raw, key, Map.fetch!(track, field))
    end)
  end

  defp recognized_codec?(codec) do
    codec in ["opus", "pcm", "flac", "mp3", "ulaw", "alaw"] or
      String.starts_with?(codec, ["avc1.", "avc3.", "hev1.", "hvc1.", "av01.", "vp09.", "mp4a."]) or
      codec == "vp8"
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
