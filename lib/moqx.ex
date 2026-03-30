defmodule MOQX do
  @moduledoc """
  Elixir bindings for Media over QUIC (MOQ) over WebTransport.

  `MOQX` exposes one clear, supported flow:

  1. connect a publisher session with `connect_publisher/1`
  2. connect a subscriber session with `connect_subscriber/1`
  3. publish a broadcast with `publish/2`
  4. create one or more tracks with `create_track/2`
  5. send frames with `write_frame/2`
  6. subscribe with `subscribe/3`

  Connection and subscription are asynchronous:

  - `connect_publisher/1`, `connect_subscriber/1`, and `connect/2` return `:ok` immediately
  - the caller later receives `{:moqx_connected, session}` or `{:error, reason}`
  - `subscribe/3` returns `:ok` immediately
  - the caller later receives subscription lifecycle messages

  ## Example

      :ok = MOQX.connect_publisher("https://relay.example.com")

      publisher =
        receive do
          {:moqx_connected, session} -> session
          {:error, reason} -> raise "publisher connect failed: \#{inspect(reason)}"
        end

      {:ok, broadcast} = MOQX.publish(publisher, "anon/demo")
      {:ok, track} = MOQX.create_track(broadcast, "video")
      :ok = MOQX.write_frame(track, "frame-1")
      :ok = MOQX.finish_track(track)

      :ok = MOQX.connect_subscriber("https://relay.example.com")

      subscriber =
        receive do
          {:moqx_connected, session} -> session
          {:error, reason} -> raise "subscriber connect failed: \#{inspect(reason)}"
        end

      :ok = MOQX.subscribe(subscriber, "anon/demo", "video")

      receive do
        {:moqx_subscribed, "anon/demo", "video"} -> :ok
      end

      receive do
        {:moqx_frame, 0, payload} -> payload
      end

      receive do
        {:moqx_track_ended} -> :ok
      end

  Broadcast announcement is lazy: a broadcast becomes visible to subscribers
  on the first successful `write_frame/2` for any track in that broadcast.
  """

  @typedoc "Publisher or subscriber session role."
  @type role :: :publisher | :subscriber

  @typedoc "Opaque session resource returned in `{:moqx_connected, session}`."
  @opaque session :: reference()

  @typedoc "Opaque broadcast resource returned by `publish/2`."
  @opaque broadcast :: reference()

  @typedoc "Opaque track resource returned by `create_track/2`."
  @opaque track :: reference()

  @typedoc "Connection result delivered to the caller process."
  @type connect_message :: {:moqx_connected, session()} | {:error, String.t()}

  @typedoc "Subscription messages delivered to the caller process."
  @type subscribe_message ::
          {:moqx_subscribed, String.t(), String.t()}
          | {:moqx_frame, non_neg_integer(), binary()}
          | {:moqx_track_ended}
          | {:moqx_error, String.t()}

  @doc """
  Connects to a relay with an explicit role.

  Prefer `connect_publisher/1` and `connect_subscriber/1` unless you need to
  select the role dynamically.

  Returns `:ok` immediately. The caller later receives a `t:connect_message/0`.
  """
  @spec connect(String.t(), role: role()) :: :ok | {:error, String.t()}
  def connect(url, opts) when is_binary(url) and is_list(opts) do
    role =
      case Keyword.fetch(opts, :role) do
        {:ok, value} -> normalize_connect_role!(value)
        :error -> raise ArgumentError, "connect/2 requires :role (:publisher or :subscriber)"
      end

    MOQX.Native.connect(url, role)
  end

  @doc """
  Connects a publisher session.

  Returns `:ok` immediately. The caller later receives a `t:connect_message/0`.
  """
  @spec connect_publisher(String.t()) :: :ok | {:error, String.t()}
  def connect_publisher(url) when is_binary(url) do
    connect(url, role: :publisher)
  end

  @doc """
  Connects a subscriber session.

  Returns `:ok` immediately. The caller later receives a `t:connect_message/0`.
  """
  @spec connect_subscriber(String.t()) :: :ok | {:error, String.t()}
  def connect_subscriber(url) when is_binary(url) do
    connect(url, role: :subscriber)
  end

  @doc """
  Closes a session.
  """
  @spec close(session()) :: :ok
  def close(session) do
    MOQX.Native.session_close(session)
  end

  @doc false
  @spec session_role(session()) :: role()
  def session_role(session) do
    session
    |> MOQX.Native.session_role()
    |> normalize_session_role!()
  end

  defp normalize_connect_role!(:publisher), do: "publisher"
  defp normalize_connect_role!(:subscriber), do: "subscriber"

  defp normalize_connect_role!(role) do
    raise ArgumentError,
          "expected :role to be :publisher or :subscriber, got: #{inspect(role)}"
  end

  defp normalize_session_role!("publisher"), do: :publisher
  defp normalize_session_role!("subscriber"), do: :subscriber

  # ---------------------------------------------------------------------------
  # Publish
  # ---------------------------------------------------------------------------

  @doc """
  Creates a broadcast handle for the given path on a publisher session.

  The broadcast is announced lazily on the first successful `write_frame/2`.

  Misuse errors, such as calling this with a subscriber session, are returned as
  `{:error, reason}` immediately.
  """
  @spec publish(session(), String.t()) :: {:ok, broadcast()} | {:error, String.t()}
  def publish(session, broadcast_path) when is_binary(broadcast_path) do
    MOQX.Native.publish(session, broadcast_path)
  end

  @doc """
  Creates a named track inside a broadcast.
  """
  @spec create_track(broadcast(), String.t()) :: {:ok, track()} | {:error, String.t()}
  def create_track(broadcast, track_name) when is_binary(track_name) do
    MOQX.Native.create_track(broadcast, track_name)
  end

  @doc """
  Writes one frame to a track.

  Each call creates the next group in that track. Group sequence numbers are
  delivered to subscribers in `{:moqx_frame, group_seq, payload}` messages.
  """
  @spec write_frame(track(), binary()) :: :ok | {:error, String.t()}
  def write_frame(track, data) when is_binary(data) do
    MOQX.Native.write_frame(track, data)
  end

  @doc """
  Finishes a track.

  Subscribers receive `{:moqx_track_ended}` after the track is fully consumed.
  """
  @spec finish_track(track()) :: :ok | {:error, String.t()}
  def finish_track(track) do
    MOQX.Native.finish_track(track)
  end

  # ---------------------------------------------------------------------------
  # Subscribe
  # ---------------------------------------------------------------------------

  @doc """
  Subscribes a subscriber session to one track in a broadcast.

  Returns `:ok` immediately. The caller later receives a
  `t:subscribe_message/0` stream:

  - `{:moqx_subscribed, broadcast_path, track_name}` when the subscription is active
  - `{:moqx_frame, group_seq, payload}` for each frame
  - `{:moqx_track_ended}` when the track finishes cleanly
  - `{:moqx_error, reason}` for asynchronous runtime failures

  Misuse errors, such as calling this with a publisher session, are returned as
  `{:error, reason}` immediately.
  """
  @spec subscribe(session(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def subscribe(session, broadcast_path, track_name)
      when is_binary(broadcast_path) and is_binary(track_name) do
    MOQX.Native.subscribe(session, broadcast_path, track_name)
  end
end
