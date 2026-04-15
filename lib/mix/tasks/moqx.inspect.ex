defmodule Mix.Tasks.Moqx.Inspect do
  @moduledoc """
  Connects to a relay, loads a catalog when available, lets you choose a track,
  then prints live runtime stats (bandwidth, groups/s, objects/s, PRFT latency
  when present).

  ## Usage

      mix moqx.inspect [relay_url] [options]

  Examples:

      mix moqx.inspect
      mix moqx.inspect --track 259
      mix moqx.inspect https://ord.abr.moqtail.dev --namespace moqtail
      mix moqx.inspect https://draft-14.cloudflare.mediaoverquic.com --namespace bbb --catalog-track .catalog --list-tracks-only
      mix moqx.inspect https://draft-14.cloudflare.mediaoverquic.com --namespace bbb --no-fetch --list-tracks-only

  Options:

    * `--namespace` - catalog/subscription namespace (default: `"moqtail"`).
    * `--catalog-track` - explicit catalog track name. When omitted, `moqx`
      tries `"catalog"` and then `".catalog"`.
    * `--no-fetch` - skip catalog fetch and go directly to live subscribe.
    * `--track` - track name to subscribe to directly (skips interactive prompt).
    * `--list-tracks-only` - load a catalog, print tracks, and exit.
    * `--timeout` - connect/catalog/subscription timeout in ms (default: `10_000`).
      When explicitly provided, it is also used as a max stream runtime;
      when it expires, the task exits cleanly.
    * `--interval-ms` - stats print interval in ms (default: `1_000`).
    * `--delivery-timeout-ms` - passed through to `MOQX.subscribe/4`.
    * `--show-raw` - include full per-track raw catalog maps in listing output.
    * `--help` - prints this help.
  """
  use Mix.Task

  @shortdoc "Inspect relay catalogs/tracks and print live subscription stats"
  @requirements ["app.start"]

  @default_relay_url "https://ord.abr.moqtail.dev"
  @default_namespace "moqtail"
  @default_catalog_tracks ["catalog", ".catalog"]

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
          catalog_track: :string,
          no_fetch: :boolean,
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
        {:ok, build_config(opts, positional)}
    end
  end

  defp build_config(opts, positional) do
    url = List.first(positional) || @default_relay_url
    timeout = positive_int!(opts[:timeout], :timeout, 10_000)
    run_timeout_ms = if(opts[:timeout], do: positive_int!(opts[:timeout], :timeout, nil))

    %{
      url: url,
      namespace: opts[:namespace] || @default_namespace,
      catalog_tracks: catalog_tracks(opts),
      skip_fetch?: opts[:no_fetch] || false,
      track_name: opts[:track],
      list_tracks_only: opts[:list_tracks_only] || false,
      timeout: timeout,
      run_timeout_ms: run_timeout_ms,
      interval_ms: positive_int!(opts[:interval_ms], :interval_ms, 1_000),
      subscribe_opts: build_subscribe_opts(opts),
      show_raw: opts[:show_raw] || false
    }
  end

  defp catalog_tracks(opts) do
    case opts[:catalog_track] do
      nil -> @default_catalog_tracks
      track -> [track]
    end
  end

  defp run_with_config(config) do
    Mix.shell().info("connecting to #{config.url} as subscriber...")
    connect_ref = connect_subscriber!(config.url, config.timeout)
    subscriber = await_connected!(connect_ref, config.timeout)

    try do
      cond do
        config.list_tracks_only ->
          Mix.shell().info(catalog_load_message(config.namespace, config.catalog_tracks))

          case load_catalog(
                 subscriber,
                 config.namespace,
                 config.catalog_tracks,
                 config.timeout,
                 config.skip_fetch?
               ) do
            {:ok, catalog} ->
              print_available_tracks!(catalog, config.show_raw)

            {:error, reason} ->
              Mix.raise("catalog unavailable: #{reason}")
          end

        is_binary(config.track_name) ->
          run_stream_for_track!(subscriber, config, config.track_name)

        true ->
          Mix.shell().info(catalog_load_message(config.namespace, config.catalog_tracks))

          track_name =
            case load_catalog(
                   subscriber,
                   config.namespace,
                   config.catalog_tracks,
                   config.timeout,
                   config.skip_fetch?
                 ) do
              {:ok, catalog} ->
                choose_track!(catalog, nil, config.show_raw).name

              {:error, reason} ->
                Mix.shell().error("catalog unavailable: #{reason}")
                prompt_track_name_without_catalog!()
            end

          run_stream_for_track!(subscriber, config, track_name)
      end
    after
      :ok = MOQX.close(subscriber)
    end
  end

  defp catalog_load_message(namespace, catalog_tracks) do
    "loading catalog (namespace=#{namespace}, tracks=#{Enum.join(catalog_tracks, ", ")})..."
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
      {:ok, connect_ref} ->
        connect_ref

      {:error, %MOQX.RequestError{message: reason}} ->
        hint =
          if String.contains?(reason, "connection closed by peer") do
            " (relay may require a different root path and/or JWT in ?jwt=...)"
          else
            ""
          end

        Mix.raise("connect failed: #{reason}#{hint}")
    end
  end

  defp await_connected!(connect_ref, timeout) do
    receive do
      {:moqx_connect_ok, %MOQX.ConnectOk{ref: ^connect_ref, session: session}} ->
        session

      {:moqx_request_error, %MOQX.RequestError{op: :connect, ref: ^connect_ref, message: reason}} ->
        Mix.raise("connect failed: #{reason}")

      {:moqx_transport_error,
       %MOQX.TransportError{op: :connect, ref: ^connect_ref, message: reason}} ->
        Mix.raise("connect failed: #{reason}")
    after
      timeout -> Mix.raise("timed out waiting for connect")
    end
  end

  defp load_catalog(subscriber, namespace, catalog_tracks, timeout, skip_fetch?) do
    do_load_catalog(subscriber, namespace, catalog_tracks, timeout, skip_fetch?, nil)
  end

  defp do_load_catalog(_subscriber, _namespace, [], _timeout, _skip_fetch?, nil) do
    {:error, "no catalog tracks configured"}
  end

  defp do_load_catalog(_subscriber, _namespace, [], _timeout, _skip_fetch?, last_error) do
    {:error, last_error}
  end

  defp do_load_catalog(subscriber, namespace, [catalog_track | rest], timeout, true, _last_error) do
    subscribe_catalog_or_retry(
      subscriber,
      namespace,
      catalog_track,
      rest,
      timeout,
      "fetch skipped"
    )
  end

  defp do_load_catalog(subscriber, namespace, [catalog_track | rest], timeout, false, _last_error) do
    case fetch_catalog(subscriber, namespace, catalog_track, timeout) do
      {:ok, catalog} ->
        {:ok, catalog}

      {:error, reason} ->
        handle_catalog_fetch_error(subscriber, namespace, catalog_track, rest, timeout, reason)
    end
  end

  defp handle_catalog_fetch_error(subscriber, namespace, catalog_track, rest, timeout, reason) do
    if catalog_fetch_fallback_reason?(reason) do
      fallback_to_catalog_subscribe(subscriber, namespace, catalog_track, rest, timeout, reason)
    else
      catalog_retry_or_error(
        subscriber,
        namespace,
        rest,
        timeout,
        false,
        catalog_track,
        reason,
        nil
      )
    end
  end

  defp fallback_to_catalog_subscribe(subscriber, namespace, catalog_track, rest, timeout, reason) do
    Mix.shell().info(
      "catalog fetch on #{catalog_track} was unavailable (#{reason}); falling back to live subscribe..."
    )

    fallback_reason = subscribe_catalog_fallback_reason(reason, catalog_track)

    case subscribe_catalog(subscriber, namespace, catalog_track, timeout) do
      {:ok, catalog} ->
        {:ok, catalog}

      {:error, subscribe_reason} ->
        catalog_retry_or_error(
          subscriber,
          namespace,
          rest,
          timeout,
          false,
          catalog_track,
          fallback_reason,
          subscribe_reason
        )
    end
  end

  defp subscribe_catalog_or_retry(subscriber, namespace, catalog_track, rest, timeout, reason) do
    Mix.shell().info("skipping catalog fetch for #{catalog_track}; using live subscribe...")

    case subscribe_catalog(subscriber, namespace, catalog_track, timeout) do
      {:ok, catalog} ->
        {:ok, catalog}

      {:error, subscribe_reason} ->
        catalog_retry_or_error(
          subscriber,
          namespace,
          rest,
          timeout,
          true,
          catalog_track,
          reason,
          subscribe_reason
        )
    end
  end

  defp catalog_retry_or_error(
         subscriber,
         namespace,
         rest,
         timeout,
         skip_fetch?,
         catalog_track,
         fetch_reason,
         subscribe_reason
       ) do
    formatted = format_catalog_attempt_error(catalog_track, fetch_reason, subscribe_reason)

    case rest do
      [] ->
        {:error, formatted}

      _ ->
        do_load_catalog(subscriber, namespace, rest, timeout, skip_fetch?, formatted)
    end
  end

  defp subscribe_catalog_fallback_reason(reason, _catalog_track), do: reason

  defp format_catalog_attempt_error(catalog_track, fetch_reason, nil) do
    "track #{inspect(catalog_track)} failed: #{fetch_reason}"
  end

  defp format_catalog_attempt_error(catalog_track, fetch_reason, subscribe_reason) do
    "track #{inspect(catalog_track)} failed: fetch=#{fetch_reason}; subscribe=#{subscribe_reason}"
  end

  defp catalog_fetch_fallback_reason?(reason) when is_binary(reason) do
    reason == "timeout" or
      String.contains?(reason, "NoObjects") or
      String.contains?(reason, "TrackDoesNotExist") or
      String.contains?(reason, "Track does not exist")
  end

  defp catalog_fetch_fallback_reason?(_reason), do: false

  defp fetch_catalog(subscriber, namespace, catalog_track, timeout) do
    with {:ok, ref} <-
           MOQX.Helpers.fetch_catalog(subscriber, namespace: namespace, track: catalog_track),
         {:ok, catalog} <- MOQX.Helpers.await_catalog(ref, timeout) do
      {:ok, catalog}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp subscribe_catalog(subscriber, namespace, catalog_track, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    subscribe_catalog_loop(subscriber, namespace, catalog_track, deadline)
  end

  defp subscribe_catalog_loop(subscriber, namespace, catalog_track, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, "timed out waiting for first catalog object"}
    else
      do_subscribe_catalog_loop(subscriber, namespace, catalog_track, deadline, remaining)
    end
  end

  defp do_subscribe_catalog_loop(subscriber, namespace, catalog_track, deadline, remaining) do
    {:ok, sub_ref} = MOQX.subscribe(subscriber, namespace, catalog_track)
    await_subscribed!(sub_ref, namespace, catalog_track, remaining)

    case await_catalog_payload(sub_ref, min(1_000, remaining)) do
      {:ok, payload} -> decode_catalog_payload(payload)
      :retry -> subscribe_catalog_loop(subscriber, namespace, catalog_track, deadline)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_catalog_payload(payload) do
    case MOQX.Catalog.decode(payload) do
      {:ok, catalog} -> {:ok, catalog}
      {:error, reason} -> {:error, "catalog decode failed: #{reason}"}
    end
  end

  defp await_catalog_payload(sub_ref, timeout) do
    receive do
      {:moqx_object,
       %MOQX.ObjectReceived{handle: ^sub_ref, object: %MOQX.Object{payload: payload}}} ->
        {:ok, payload}

      {:moqx_track_init, %MOQX.TrackInit{handle: ^sub_ref}} ->
        await_catalog_payload(sub_ref, timeout)

      {:moqx_end_of_group, %MOQX.EndOfGroup{handle: ^sub_ref}} ->
        await_catalog_payload(sub_ref, timeout)

      {:moqx_publish_done, %MOQX.PublishDone{handle: ^sub_ref, message: reason, code: code}} ->
        detail =
          [reason, if(is_integer(code), do: "code=#{code}")]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        {:error,
         "catalog track ended before first object#{if(detail != "", do: ": #{detail}", else: "")}"}

      {:moqx_request_error, %MOQX.RequestError{op: :subscribe, handle: ^sub_ref, message: reason}} ->
        {:error, reason}

      {:moqx_transport_error,
       %MOQX.TransportError{op: :subscribe, handle: ^sub_ref, message: reason}} ->
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
        "role=#{inspect(pick_track_value(track, "role"))}",
        "codec=#{inspect(pick_track_value(track, "codec"))}",
        "packaging=#{inspect(pick_track_value(track, "packaging"))}",
        "init_track=#{inspect(track.raw["initTrack"])}",
        format_track_variant(track)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
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

  defp pick_track_value(track, key) do
    track.raw[key] || get_in(track.raw, ["selectionParams", key])
  end

  defp format_track_variant(track) do
    width = pick_track_value(track, "width")
    height = pick_track_value(track, "height")
    samplerate = pick_track_value(track, "samplerate")
    bitrate = pick_track_value(track, "bitrate")

    cond do
      width && height ->
        "resolution=#{width}x#{height}"

      samplerate ->
        channels = pick_track_value(track, "channelConfig")
        suffix = if is_binary(channels), do: " channels=#{channels}", else: ""
        "samplerate=#{samplerate}#{suffix}"

      bitrate ->
        "bitrate=#{bitrate}"

      true ->
        nil
    end
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

  defp prompt_track_name_without_catalog! do
    Mix.shell().info("catalog is unavailable; enter a track name manually (or q)")

    case IO.gets("Track name: ") do
      :eof ->
        Mix.raise("stdin closed")

      nil ->
        Mix.raise("stdin closed")

      input ->
        case String.trim(input) do
          "" -> prompt_track_name_without_catalog!()
          "q" -> Mix.raise("aborted")
          "quit" -> Mix.raise("aborted")
          name -> name
        end
    end
  end

  defp await_subscribed!(sub_ref, namespace, track_name, timeout) do
    receive do
      {:moqx_subscribe_ok,
       %MOQX.SubscribeOk{handle: ^sub_ref, namespace: ^namespace, track_name: ^track_name}} ->
        :ok

      {:moqx_request_error, %MOQX.RequestError{op: :subscribe, handle: ^sub_ref, message: reason}} ->
        Mix.raise("subscribe failed: #{reason}")

      {:moqx_transport_error,
       %MOQX.TransportError{op: :subscribe, handle: ^sub_ref, message: reason}} ->
        Mix.raise("subscribe transport failure: #{reason}")
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
          {:moqx_object,
           %MOQX.ObjectReceived{object: %MOQX.Object{group_id: group_id, payload: payload}}} ->
            stream_stats_loop(
              interval_ms,
              DemoDebugStats.add_frame(stats, group_id, payload),
              stream_started_mono_ms,
              run_timeout_ms,
              next_tick_mono_ms
            )

          {:moqx_end_of_group, %MOQX.EndOfGroup{}} ->
            stream_stats_loop(
              interval_ms,
              stats,
              stream_started_mono_ms,
              run_timeout_ms,
              next_tick_mono_ms
            )

          {:moqx_transport_error, %MOQX.TransportError{message: reason}} ->
            Mix.raise("stream error: #{reason}")

          {:moqx_publish_done, %MOQX.PublishDone{}} ->
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
