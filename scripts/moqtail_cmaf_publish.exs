defmodule MOQX.Scripts.MoqtailCMAFPublish do
  @moduledoc false

  @default_endpoint "moqt://relay.moqtail.dev:443"

  def run(argv) do
    with {:ok, config} <- parse(argv),
         {:ok, client} <-
           MOQX.connect(config.endpoint,
             protocol: :draft_16,
             timeout: config.timeout
           ) do
      try do
        publish(client, config)
      after
        _result = MOQX.close(client)
      end
    else
      {:error, :usage} -> usage()
      {:error, reason} -> raise "Moqtail CMAF publication failed: #{inspect(reason)}"
    end
  end

  defp publish(client, config) do
    print_plan(config)

    publish_options = [
      namespace: config.namespace,
      catalog_track: "catalog",
      media_track: config.media_track,
      codec: config.codec,
      width: config.width,
      height: config.height,
      bitrate: config.bitrate,
      timescale: config.timescale,
      delivery: config.delivery,
      catalog_repetitions: config.catalog_repetitions,
      catalog_interval: config.catalog_interval,
      fragment_interval: config.fragment_interval,
      timeout: config.timeout
    ]

    with {:ok, published} <-
           MOQX.CMAF.publish_file(client, config.input, publish_options),
         :ok <- MOQX.finish_publication(client, published.publication) do
      IO.puts(
        "published #{published.fragment_count} CMAF fragment(s); publication finished cleanly"
      )

      :ok
    end
  end

  defp print_plan(config) do
    discovery_window =
      max(config.catalog_repetitions - 1, 0) * config.catalog_interval

    IO.puts("namespace: #{Enum.join(config.namespace, "/")}")
    IO.puts("player: #{player_url(config.endpoint, config.namespace)}")

    IO.puts(
      "announcing the catalog #{config.catalog_repetitions} time(s) over " <>
        "#{discovery_window} ms, then publishing the media once"
    )

    :ok
  end

  defp parse(argv) do
    {options, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          endpoint: :string,
          namespace: :string,
          media_track: :string,
          codec: :string,
          width: :integer,
          height: :integer,
          bitrate: :integer,
          timescale: :integer,
          delivery: :string,
          catalog_repetitions: :integer,
          catalog_interval: :integer,
          fragment_interval: :integer,
          timeout: :integer
        ]
      )

    with [] <- invalid,
         [input] <- positional,
         {:ok, namespace} <- namespace(options[:namespace]),
         {:ok, delivery} <- delivery(Keyword.get(options, :delivery, "subgroup")),
         config <- %{
           input: input,
           endpoint: Keyword.get(options, :endpoint, @default_endpoint),
           namespace: namespace,
           media_track: Keyword.get(options, :media_track, "video"),
           codec: Keyword.get(options, :codec, "avc1.42C01F"),
           width: options[:width],
           height: options[:height],
           bitrate: options[:bitrate],
           timescale: Keyword.get(options, :timescale, 90_000),
           delivery: delivery,
           catalog_repetitions: Keyword.get(options, :catalog_repetitions, 10),
           catalog_interval: Keyword.get(options, :catalog_interval, 1_000),
           fragment_interval: Keyword.get(options, :fragment_interval, 250),
           timeout: Keyword.get(options, :timeout, 15_000)
         },
         true <- valid_config?(config) do
      {:ok, config}
    else
      _other -> {:error, :usage}
    end
  end

  defp namespace(nil) do
    suffix =
      "#{System.system_time(:second)}-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, ["moqx", "publish-" <> suffix]}
  end

  defp namespace(value) do
    case String.split(value, "/", trim: true) do
      [] -> {:error, :invalid_namespace}
      fields -> {:ok, fields}
    end
  end

  defp delivery("subgroup"), do: {:ok, :subgroup}
  defp delivery("datagram"), do: {:ok, :datagram}
  defp delivery(_delivery), do: {:error, :invalid_delivery}

  defp valid_config?(config) do
    Enum.all?(
      [config.catalog_repetitions, config.timescale, config.timeout],
      &(is_integer(&1) and &1 > 0)
    ) and
      is_integer(config.catalog_interval) and config.catalog_interval >= 0 and
      is_integer(config.fragment_interval) and config.fragment_interval >= 0 and
      positive_optional?(config.width) and positive_optional?(config.height) and
      positive_optional?(config.bitrate) and config.media_track != "" and config.codec != ""
  end

  defp positive_optional?(nil), do: true
  defp positive_optional?(value), do: is_integer(value) and value > 0

  defp player_url(endpoint, namespace) do
    endpoint = URI.parse(endpoint)
    path = if endpoint.path in [nil, "/"], do: "", else: endpoint.path

    encoded_namespace =
      namespace
      |> Enum.map(&encode_msf_field/1)
      |> Enum.join("-")

    msf_url = "moqt://#{endpoint.authority}#{path}#msf:#{encoded_namespace}"
    "https://player.moqtail.dev/?url=#{URI.encode_www_form(msf_url)}"
  end

  defp encode_msf_field(field) do
    field
    |> :binary.bin_to_list()
    |> Enum.map_join(fn byte ->
      if (byte >= ?a and byte <= ?z) or (byte >= ?A and byte <= ?Z) or
           (byte >= ?0 and byte <= ?9) or byte == ?_ do
        <<byte>>
      else
        "." <> Base.encode16(<<byte>>, case: :lower)
      end
    end)
  end

  defp usage do
    raise """
    usage: mix run scripts/moqtail_cmaf_publish.exs INPUT.mp4 [options]

      --endpoint moqt://HOST:443       default: #{@default_endpoint}
      --namespace FIELD/FIELD          default: generated unique namespace
      --media-track NAME               default: video
      --codec AVC-CODEC                default: avc1.42C01F
      --width PIXELS --height PIXELS   optional CMSF video dimensions
      --bitrate BPS                    optional CMSF bitrate
      --timescale HZ                   default: 90000
      --delivery subgroup|datagram     default: subgroup
      --catalog-repetitions COUNT      default: 10
      --catalog-interval MS            default: 1000
      --fragment-interval MS           default: 250
      --timeout MS                     default: 15000
    """
  end
end

MOQX.Scripts.MoqtailCMAFPublish.run(System.argv())
