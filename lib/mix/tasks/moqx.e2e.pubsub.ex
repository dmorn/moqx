defmodule Mix.Tasks.Moqx.E2e.Pubsub do
  @moduledoc """
  End-to-end relay smoke test: connect publisher + subscriber, publish one frame,
  and verify the subscriber receives it.

  ## Usage

      mix moqx.e2e.pubsub [relay_url] [options]

  Examples:

      mix moqx.e2e.pubsub
      mix moqx.e2e.pubsub https://interop-relay.cloudflare.mediaoverquic.com:443
      mix moqx.e2e.pubsub --namespace moqx-e2e/demo --track demo --payload hello

  Options:

    * `--namespace` - broadcast namespace to publish/subscribe.
      Default: `"moqx-e2e/<unix_ms>"`.
    * `--track` - track name. Default: `"demo"`.
    * `--payload` - frame payload to send. Default: `"hello-from-moqx-e2e"`.
    * `--timeout` - timeout in ms for each await step. Default: `10_000`.
    * `--help` - print this help.
  """

  use Mix.Task

  @shortdoc "Run a publish+subscribe E2E relay smoke test"
  @requirements ["app.start"]

  @default_relay_url "https://ord.abr.moqtail.dev"

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      :help ->
        Mix.shell().info(@moduledoc)

      {:error, message} ->
        Mix.raise(message)

      {:ok, cfg} ->
        run_e2e(cfg)
    end
  end

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          namespace: :string,
          track: :string,
          payload: :string,
          timeout: :integer,
          help: :boolean
        ]
      )

    cond do
      opts[:help] ->
        :help

      invalid != [] ->
        {:error, "invalid options: #{inspect(invalid)}"}

      true ->
        relay_url = List.first(positional) || @default_relay_url
        namespace = opts[:namespace] || default_namespace()
        track = opts[:track] || "demo"
        payload = opts[:payload] || "hello-from-moqx-e2e"
        timeout = positive_int!(opts[:timeout], :timeout, 10_000)

        {:ok,
         %{
           relay_url: relay_url,
           namespace: namespace,
           track: track,
           payload: payload,
           timeout: timeout
         }}
    end
  end

  defp default_namespace do
    "moqx-e2e/#{System.system_time(:millisecond)}"
  end

  defp run_e2e(cfg) do
    Mix.shell().info("relay: #{cfg.relay_url}")
    Mix.shell().info("namespace/track: #{cfg.namespace}/#{cfg.track}")

    :ok = MOQX.connect_publisher(cfg.relay_url)
    publisher = await_connected!(cfg.timeout, :publisher)

    :ok = MOQX.connect_subscriber(cfg.relay_url)
    subscriber = await_connected!(cfg.timeout, :subscriber)

    try do
      {:ok, broadcast} = MOQX.publish(publisher, cfg.namespace)
      {:ok, track} = MOQX.create_track(broadcast, cfg.track)

      # Some relays need a brief window to register the just-published namespace.
      Process.sleep(300)

      subscribe_with_retry!(subscriber, cfg.namespace, cfg.track, cfg.timeout)

      # Send a few frames to smooth over first-object timing on remote relays.
      Enum.each(1..3, fn _ ->
        :ok = MOQX.write_frame(track, cfg.payload)
        Process.sleep(100)
      end)

      {group_id, payload} = await_matching_payload_frame!(cfg.payload, cfg.timeout)

      if payload != cfg.payload do
        Mix.raise(
          "payload mismatch: expected=#{inspect(cfg.payload)} got=#{inspect(payload)} group=#{group_id}"
        )
      end

      :ok = MOQX.finish_track(track)

      Mix.shell().info("E2E OK: group=#{group_id} payload=#{inspect(payload)}")
    after
      :ok = MOQX.close(subscriber)
      :ok = MOQX.close(publisher)
    end
  end

  defp await_connected!(timeout, role) do
    receive do
      {:moqx_connected, session} ->
        if MOQX.session_role(session) != role do
          Mix.raise(
            "expected #{role} session, got #{inspect(MOQX.session_role(session))} (#{MOQX.session_version(session)})"
          )
        end

        session

      {:error, reason} ->
        Mix.raise("connect failed (#{role}): #{inspect(reason)}")
    after
      timeout ->
        Mix.raise("connect timeout (#{role})")
    end
  end

  defp subscribe_with_retry!(subscriber, namespace, track_name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    subscribe_with_retry_loop(subscriber, namespace, track_name, deadline)
  end

  defp subscribe_with_retry_loop(subscriber, namespace, track_name, deadline) do
    :ok = MOQX.subscribe(subscriber, namespace, track_name)

    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Mix.raise("subscribe timeout for #{namespace}/#{track_name}")
    else
      receive do
        {:moqx_subscribed, ^namespace, ^track_name} ->
          :ok

        {:moqx_error, reason} ->
          if retryable_subscribe_reason?(reason) do
            Process.sleep(150)
            subscribe_with_retry_loop(subscriber, namespace, track_name, deadline)
          else
            Mix.raise("subscribe failed: #{inspect(reason)}")
          end
      after
        min(1_000, remaining) ->
          subscribe_with_retry_loop(subscriber, namespace, track_name, deadline)
      end
    end
  end

  defp await_matching_payload_frame!(expected_payload, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_matching_payload_frame_loop(expected_payload, deadline)
  end

  defp await_matching_payload_frame_loop(expected_payload, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Mix.raise("frame timeout waiting for payload #{inspect(expected_payload)}")
    else
      receive do
        {:moqx_frame, group_id, payload} when payload == expected_payload ->
          {group_id, payload}

        {:moqx_frame, _group_id, _payload} ->
          await_matching_payload_frame_loop(expected_payload, deadline)

        {:moqx_error, reason} ->
          Mix.raise("frame receive failed: #{inspect(reason)}")
      after
        remaining ->
          Mix.raise("frame timeout waiting for payload #{inspect(expected_payload)}")
      end
    end
  end

  defp retryable_subscribe_reason?(reason) when is_binary(reason) do
    String.contains?(reason, "Unknown track namespace") or
      String.contains?(reason, "internal error")
  end

  defp retryable_subscribe_reason?(_reason), do: false

  defp positive_int!(nil, _name, default), do: default

  defp positive_int!(value, _name, _default) when is_integer(value) and value > 0, do: value

  defp positive_int!(value, name, _default) do
    Mix.raise("#{name} must be a positive integer, got: #{inspect(value)}")
  end
end
