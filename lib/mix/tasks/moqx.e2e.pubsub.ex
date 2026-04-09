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

      :ok = MOQX.subscribe(subscriber, cfg.namespace, cfg.track)
      await_subscribed!(cfg.namespace, cfg.track, cfg.timeout)

      :ok = MOQX.write_frame(track, cfg.payload)

      {group_id, payload} = await_frame!(cfg.timeout)

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

  defp await_subscribed!(namespace, track_name, timeout) do
    receive do
      {:moqx_subscribed, ^namespace, ^track_name} -> :ok
      {:moqx_error, reason} -> Mix.raise("subscribe failed: #{inspect(reason)}")
    after
      timeout -> Mix.raise("subscribe timeout for #{namespace}/#{track_name}")
    end
  end

  defp await_frame!(timeout) do
    receive do
      {:moqx_frame, group_id, payload} -> {group_id, payload}
      {:moqx_error, reason} -> Mix.raise("frame receive failed: #{inspect(reason)}")
    after
      timeout -> Mix.raise("frame timeout")
    end
  end

  defp positive_int!(nil, _name, default), do: default

  defp positive_int!(value, _name, _default) when is_integer(value) and value > 0, do: value

  defp positive_int!(value, name, _default) do
    Mix.raise("#{name} must be a positive integer, got: #{inspect(value)}")
  end
end
