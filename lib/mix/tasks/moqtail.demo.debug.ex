defmodule Mix.Tasks.Moqtail.Demo.Debug do
  @moduledoc """
  Connects to a relay, fetches a catalog, lets you choose a track, then prints
  live runtime stats (bandwidth, groups/s, objects/s, PRFT latency when present).

  ## Usage

      mix moqtail.demo.debug [relay_url] [options]

  Examples:

      mix moqtail.demo.debug
      mix moqtail.demo.debug --track 259
      mix moqtail.demo.debug https://ord.abr.moqtail.dev --namespace moqtail
      mix moqtail.demo.debug https://ord.abr.moqtail.dev --namespace moqtail --list-tracks-only

  Options:

    * `--namespace` - catalog/subscription namespace (default: `"moqtail"`).
    * `--track` - track name to subscribe to directly (skips interactive prompt).
    * `--list-tracks-only` - fetch/subscribe catalog, print tracks, and exit.
    * `--timeout` - connect/catalog/subscription timeout in ms (default: `10_000`).
      When explicitly provided, it is also used as a max stream runtime;
      when it expires, the task exits cleanly.
    * `--interval-ms` - stats print interval in ms (default: `1_000`).
    * `--delivery-timeout-ms` - passed through to `MOQX.subscribe/4`.
    * `--help` - prints this help.
  """
  use Mix.Task

  @shortdoc "Debug a moqtail relay track with live latency/bandwidth stats"
  @requirements ["app.start"]

  @default_relay_url "https://ord.abr.moqtail.dev"
  @default_namespace "moqtail"

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
           subscribe_opts: build_subscribe_opts(opts)
         }}
    end
  end

  defp run_with_config(config) do
    Mix.shell().info("connecting to #{config.url} as subscriber...")
    :ok = connect_subscriber!(config.url, config.timeout)
    subscriber = await_connected!(config.timeout)

    try do
      Mix.shell().info("loading catalog (namespace=#{config.namespace})...")
      catalog = load_catalog!(subscriber, config.namespace, config.timeout)

      if config.list_tracks_only do
        print_available_tracks!(catalog)
      else
        track = choose_track!(catalog, config.track_name)

        Mix.shell().info("subscribing to #{config.namespace}/#{track.name}...")
        :ok = MOQX.subscribe(subscriber, config.namespace, track.name, config.subscribe_opts)
        await_subscribed!(config.namespace, track.name, config.timeout)

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
    after
      :ok = MOQX.close(subscriber)
    end
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
        if String.contains?(reason, "NoObjects") do
          Mix.shell().info("catalog fetch returned NoObjects; falling back to live subscribe...")
          subscribe_catalog!(subscriber, namespace, timeout)
        else
          Mix.raise("catalog load failed: #{reason}")
        end
    end
  end

  defp fetch_catalog(subscriber, namespace, timeout) do
    with {:ok, ref} <- MOQX.fetch_catalog(subscriber, namespace: namespace),
         {:ok, catalog} <- MOQX.await_catalog(ref, timeout) do
      {:ok, catalog}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp subscribe_catalog!(subscriber, namespace, timeout) do
    :ok = MOQX.subscribe(subscriber, namespace, "catalog")
    await_subscribed!(namespace, "catalog", timeout)

    receive do
      {:moqx_frame, _group_id, payload} ->
        case MOQX.Catalog.decode(payload) do
          {:ok, catalog} -> catalog
          {:error, reason} -> Mix.raise("catalog decode failed: #{reason}")
        end

      {:moqx_error, reason} ->
        Mix.raise("catalog subscribe failed: #{reason}")
    after
      timeout ->
        Mix.raise("timed out waiting for first catalog object")
    end
  end

  defp choose_track!(catalog, nil) do
    tracks = print_available_tracks!(catalog)
    choose_track_loop(tracks)
  end

  defp choose_track!(catalog, track_name) when is_binary(track_name) do
    case MOQX.Catalog.get_track(catalog, track_name) do
      nil -> Mix.raise("track #{inspect(track_name)} not found in catalog")
      track -> track
    end
  end

  defp print_available_tracks!(catalog) do
    tracks = MOQX.Catalog.tracks(catalog)

    if tracks == [] do
      Mix.raise("catalog contains no tracks")
    end

    Mix.shell().info("available tracks:")

    tracks
    |> Enum.with_index(1)
    |> Enum.each(fn {track, index} ->
      Mix.shell().info(
        "#{index}. name=#{track.name} role=#{inspect(track.role)} codec=#{inspect(track.codec)} packaging=#{inspect(track.packaging)}"
      )
    end)

    tracks
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

  defp await_subscribed!(namespace, track_name, timeout) do
    receive do
      {:moqx_subscribed, ^namespace, ^track_name} -> :ok
      {:moqx_error, reason} -> Mix.raise("subscribe failed: #{reason}")
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
          {:moqx_frame, group_id, payload} ->
            stream_stats_loop(
              interval_ms,
              DemoDebugStats.add_frame(stats, group_id, payload),
              stream_started_mono_ms,
              run_timeout_ms,
              next_tick_mono_ms
            )

          {:moqx_error, reason} ->
            Mix.raise("stream error: #{reason}")

          :moqx_track_ended ->
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
