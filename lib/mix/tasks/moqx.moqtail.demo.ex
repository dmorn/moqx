defmodule Mix.Tasks.Moqx.Moqtail.Demo do
  @moduledoc """
  Connects to a relay, fetches a catalog, lets you choose a track, then prints
  live runtime stats (bandwidth, groups/s, objects/s, PRFT latency when present).

  ## Usage

      mix moqx.moqtail.demo [relay_url] [options]

  Examples:

      mix moqx.moqtail.demo
      mix moqx.moqtail.demo --track 259
      mix moqx.moqtail.demo https://ord.abr.moqtail.dev --namespace moqtail
      mix moqx.moqtail.demo https://ord.abr.moqtail.dev --namespace moqtail --list-tracks-only

  Options:

    * `--namespace` - catalog/subscription namespace (default: `"moqtail"`).
    * `--track` - track name to subscribe to directly (skips interactive prompt).
    * `--list-tracks-only` - fetch/subscribe catalog, print tracks, and exit.
    * `--timeout` - connect/catalog/subscription timeout in ms (default: `10_000`).
      When explicitly provided, it is also used as a max stream runtime;
      when it expires, the task exits cleanly.
    * `--interval-ms` - stats print interval in ms (default: `1_000`).
    * `--delivery-timeout-ms` - passed through to `MOQX.subscribe/4`.
    * `--show-raw` - include full per-track raw catalog maps in listing output.
    * `--help` - prints this help.
  """
  use Mix.Task

  @shortdoc "Debug a moqtail relay track with live latency/bandwidth stats"
  @requirements ["app.start"]

  @default_relay_url "https://ord.abr.moqtail.dev"
  @default_namespace "moqtail"

  alias MOQX.Catalog.Track
  alias MOQX.DemoDebugStats

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      :help ->
        Mix.shell().info(@moduledoc)

      {:error, message} ->
        Mix.raise(message)

      {:ok, config} ->
        run_with_config(config)
    end
  end

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          namespace: :string,
          track: :string,
          list_tracks_only: :boolean,
          timeout: :integer,
          interval_ms: :integer,
          delivery_timeout_ms: :integer,
          show_raw: :boolean,
          help: :boolean
        ]
      )

    cond do
      opts[:help] ->
        :help

      invalid != [] ->
        {:error, "invalid options: #{inspect(invalid)}"}

      true ->
        url = List.first(positional) || @default_relay_url

        timeout = positive_int!(opts[:timeout], :timeout, 10_000)
        run_timeout_ms = if(opts[:timeout], do: positive_int!(opts[:timeout], :timeout, nil))

        {:ok,
         %{
           url: url,
           namespace: opts[:namespace] || @default_namespace,
           track_name: opts[:track],
           list_tracks_only: opts[:list_tracks_only] || false,
           timeout: timeout,
           run_timeout_ms: run_timeout_ms,
           interval_ms: positive_int!(opts[:interval_ms], :interval_ms, 1_000),
           subscribe_opts: build_subscribe_opts(opts),
           show_raw: opts[:show_raw] || false
         }}
    end
  end

  defp run_with_config(config) do
    Mix.shell().info("connecting to #{config.url} as subscriber...")
    :ok = connect_subscriber!(config.url, config.timeout)
    subscriber = await_connected!(config.timeout)

    try do
      cond do
        config.list_tracks_only ->
          Mix.shell().info("loading catalog (namespace=#{config.namespace})...")
          catalog = load_catalog!(subscriber, config.namespace, config.timeout)
          print_available_tracks!(catalog, config.show_raw)

        is_binary(config.track_name) ->
          run_stream_for_track!(subscriber, config, config.track_name)

        true ->
          Mix.shell().info("loading catalog (namespace=#{config.namespace})...")
          catalog = load_catalog!(subscriber, config.namespace, config.timeout)
          track = choose_track!(catalog, nil, config.show_raw)
          run_stream_for_track!(subscriber, config, track.name)
      end
    after
      :ok = MOQX.close(subscriber)
    end
  end

  defp run_stream_for_track!(subscriber, config, track_name) do
    Mix.shell().info("subscribing to #{config.namespace}/#{track_name}...")

    {:ok, sub_ref} =
      MOQX.subscribe(subscriber, config.namespace, track_name, config.subscribe_opts)

    await_subscribed!(sub_ref, config.namespace, track_name, config.timeout)

    print_stream_start(config.interval_ms, config.run_timeout_ms)

    now_mono_ms = System.monotonic_time(:millisecond)

    stream_stats_loop(
      config.interval_ms,
      DemoDebugStats.new(),
      now_mono_ms,
      config.run_timeout_ms,
      now_mono_ms + config.interval_ms
    )
  end

  defp build_subscribe_opts(opts) do
    case opts[:delivery_timeout_ms] do
      nil -> []
      ms -> [delivery_timeout_ms: positive_int!(ms, :delivery_timeout_ms, nil)]
    end
  end

  defp print_stream_start(interval_ms, nil) do
    Mix.shell().info("streaming stats every #{interval_ms} ms (Ctrl+C to stop)")
  end

  defp print_stream_start(interval_ms, run_timeout_ms) do
    Mix.shell().info(
      "streaming stats every #{interval_ms} ms for #{run_timeout_ms} ms (Ctrl+C to stop early)"
    )
  end

  defp connect_subscriber!(url, _timeout) do
    case MOQX.connect_subscriber(url) do
      :ok ->
        :ok

      {:error, reason} ->
        hint =
          if String.contains?(reason, "connection closed by peer") do
            " (relay may require a different root path and/or JWT in ?jwt=...)"
          else
            ""
          end

        Mix.raise("connect failed: #{reason}#{hint}")
    end
  end

  defp await_connected!(timeout) do
    receive do
      {:moqx_connected, session} -> session
      {:error, reason} -> Mix.raise("connect failed: #{reason}")
    after
      timeout -> Mix.raise("timed out waiting for connect")
    end
  end

  defp load_catalog!(subscriber, namespace, timeout) do
    case fetch_catalog(subscriber, namespace, timeout) do
      {:ok, catalog} ->
        catalog

      {:error, reason} ->
        if catalog_fetch_fallback_reason?(reason) do
          Mix.shell().info(
            "catalog fetch was unavailable (#{reason}); falling back to live subscribe..."
          )

          subscribe_catalog!(subscriber, namespace, timeout)
        else
          Mix.raise("catalog load failed: #{reason}")
        end
    end
  end

  defp catalog_fetch_fallback_reason?(reason) when is_binary(reason) do
    String.contains?(reason, "NoObjects") or
      String.contains?(reason, "TrackDoesNotExist") or
      String.contains?(reason, "Track does not exist")
  end

  defp catalog_fetch_fallback_reason?(_reason), do: false

  defp fetch_catalog(subscriber, namespace, timeout) do
    with {:ok, ref} <- MOQX.fetch_catalog(subscriber, namespace: namespace),
         {:ok, catalog} <- MOQX.await_catalog(ref, timeout) do
      {:ok, catalog}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp subscribe_catalog!(subscriber, namespace, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    subscribe_catalog_loop(subscriber, namespace, deadline)
  end

  defp subscribe_catalog_loop(subscriber, namespace, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Mix.raise("timed out waiting for first catalog object")
    end

    {:ok, sub_ref} = MOQX.subscribe(subscriber, namespace, "catalog")
    await_subscribed!(sub_ref, namespace, "catalog", remaining)

    case await_catalog_payload(sub_ref, min(1_000, remaining)) do
      {:ok, payload} ->
        case MOQX.Catalog.decode(payload) do
          {:ok, catalog} -> catalog
          {:error, reason} -> Mix.raise("catalog decode failed: #{reason}")
        end

      :retry ->
        subscribe_catalog_loop(subscriber, namespace, deadline)

      {:error, reason} ->
        Mix.raise("catalog subscribe failed: #{reason}")
    end
  end

  defp await_catalog_payload(sub_ref, timeout) do
    receive do
      {:moqx_frame, ^sub_ref, _group_id, payload} ->
        {:ok, payload}

      {:moqx_track_init, ^sub_ref, _init_data, _track_meta} ->
        await_catalog_payload(sub_ref, timeout)

      {:moqx_error, ^sub_ref, reason} ->
        {:error, reason}
    after
      timeout ->
        :retry
    end
  end

  defp choose_track!(catalog, nil, show_raw?) do
    tracks = print_available_tracks!(catalog, show_raw?)
    choose_track_loop(tracks)
  end

  defp choose_track!(catalog, track_name, _show_raw?) when is_binary(track_name) do
    case MOQX.Catalog.get_track(catalog, track_name) do
      nil -> Mix.raise("track #{inspect(track_name)} not found in catalog")
      track -> track
    end
  end

  defp print_available_tracks!(catalog, show_raw?) do
    tracks = MOQX.Catalog.tracks(catalog)

    if tracks == [] do
      Mix.raise("catalog contains no tracks")
    end

    Mix.shell().info("available tracks:")

    tracks
    |> Enum.with_index(1)
    |> Enum.each(fn {track, index} ->
      Mix.shell().info("#{index}. #{format_track_line(track, show_raw?)}")
    end)

    tracks
  end

  defp format_track_line(track, show_raw?) do
    summary =
      [
        "name=#{track.name}",
        "role=#{inspect(track.role)}",
        "codec=#{inspect(track.codec)}",
        "packaging=#{inspect(track.packaging)}"
      ]
      |> Enum.join(" ")

    description = Track.describe(track)

    lines = [
      summary,
      "   explicit: #{inspect(description.explicit, limit: :infinity, printable_limit: :infinity)}",
      "   inferred: #{inspect(description.inferred, limit: :infinity, printable_limit: :infinity)}",
      "   extra: #{inspect(description.extra, limit: :infinity, printable_limit: :infinity)}"
    ]

    lines =
      if show_raw? do
        raw_lines =
          track.raw
          |> Enum.sort_by(fn {key, _value} -> key end)
          |> Enum.map(fn {key, value} ->
            "    - #{key}: #{inspect(value, limit: :infinity, printable_limit: :infinity)}"
          end)

        lines ++ ["   raw:" | raw_lines]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp choose_track_loop(tracks) do
    max = length(tracks)

    case IO.gets("Choose track [1-#{max}] (or q): ") do
      :eof ->
        Mix.raise("stdin closed")

      nil ->
        Mix.raise("stdin closed")

      input ->
        input
        |> String.trim()
        |> parse_track_selection(tracks, max)
    end
  end

  defp parse_track_selection("q", _tracks, _max), do: Mix.raise("aborted")
  defp parse_track_selection("quit", _tracks, _max), do: Mix.raise("aborted")

  defp parse_track_selection(value, tracks, max) do
    case Integer.parse(value) do
      {index, ""} when index >= 1 and index <= max ->
        Enum.at(tracks, index - 1)

      _ ->
        Mix.shell().error("invalid selection")
        choose_track_loop(tracks)
    end
  end

  defp await_subscribed!(sub_ref, namespace, track_name, timeout) do
    receive do
      {:moqx_subscribed, ^sub_ref, ^namespace, ^track_name} -> :ok
      {:moqx_error, ^sub_ref, reason} -> Mix.raise("subscribe failed: #{reason}")
    after
      timeout -> Mix.raise("timed out waiting for subscription")
    end
  end

  defp stream_stats_loop(
         interval_ms,
         stats,
         stream_started_mono_ms,
         run_timeout_ms,
         next_tick_mono_ms
       ) do
    now_mono_ms = System.monotonic_time(:millisecond)

    cond do
      stream_timed_out?(stream_started_mono_ms, now_mono_ms, run_timeout_ms) ->
        Mix.shell().info("stream timeout reached, closing")

      now_mono_ms >= next_tick_mono_ms ->
        now_ms = System.system_time(:millisecond)
        snapshot = DemoDebugStats.snapshot(stats, now_ms)
        Mix.shell().info(DemoDebugStats.format_snapshot(snapshot))

        stream_stats_loop(
          interval_ms,
          DemoDebugStats.new(now_ms),
          stream_started_mono_ms,
          run_timeout_ms,
          now_mono_ms + interval_ms
        )

      true ->
        receive_after_ms =
          receive_after_ms(next_tick_mono_ms, now_mono_ms, stream_started_mono_ms, run_timeout_ms)

        receive do
          {:moqx_frame, _sub_ref, group_id, payload} ->
            stream_stats_loop(
              interval_ms,
              DemoDebugStats.add_frame(stats, group_id, payload),
              stream_started_mono_ms,
              run_timeout_ms,
              next_tick_mono_ms
            )

          {:moqx_error, _sub_ref, reason} ->
            Mix.raise("stream error: #{reason}")

          {:moqx_track_ended, _sub_ref} ->
            Mix.shell().info("track ended")
        after
          receive_after_ms ->
            stream_stats_loop(
              interval_ms,
              stats,
              stream_started_mono_ms,
              run_timeout_ms,
              next_tick_mono_ms
            )
        end
    end
  end

  defp receive_after_ms(next_tick_mono_ms, now_mono_ms, stream_started_mono_ms, run_timeout_ms) do
    to_tick_ms = max(next_tick_mono_ms - now_mono_ms, 0)

    case run_timeout_ms do
      nil ->
        to_tick_ms

      _ ->
        min(to_tick_ms, remaining_runtime_ms(stream_started_mono_ms, now_mono_ms, run_timeout_ms))
    end
  end

  defp stream_timed_out?(_start_mono_ms, _now_mono_ms, nil), do: false

  defp stream_timed_out?(start_mono_ms, now_mono_ms, run_timeout_ms) do
    remaining_runtime_ms(start_mono_ms, now_mono_ms, run_timeout_ms) == 0
  end

  defp remaining_runtime_ms(start_mono_ms, now_mono_ms, run_timeout_ms) do
    elapsed_ms = max(now_mono_ms - start_mono_ms, 0)
    max(run_timeout_ms - elapsed_ms, 0)
  end

  defp positive_int!(nil, _name, default), do: default
  defp positive_int!(value, _name, _default) when is_integer(value) and value > 0, do: value

  defp positive_int!(value, name, _default) do
    Mix.raise("expected --#{name} to be a positive integer, got: #{inspect(value)}")
  end
end
