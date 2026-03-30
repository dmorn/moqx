defmodule MOQX do
  @moduledoc """
  Elixir bindings for Media over QUIC (MOQ) via Rustler + moq-lite.

  ## Connection

      :ok = MOQX.connect("https://relay.example.com")
      receive do
        {:moqx_connected, session} -> session
        {:error, reason} -> raise reason
      end

  ## Publishing

      {:ok, broadcast} = MOQX.publish(session, "anon/my-stream")
      {:ok, track} = MOQX.create_track(broadcast, "video")
      :ok = MOQX.write_frame(track, <<frame_data::binary>>)
      :ok = MOQX.finish_track(track)

  ## Subscribing

      :ok = MOQX.subscribe(session, "anon/my-stream", "video")
      # Then receive messages:
      #   {:moqx_subscribed, broadcast_path, track_name}
      #   {:moqx_frame, group_seq, binary_data}
      #   {:moqx_track_ended}
      #   {:moqx_error, reason}
  """

  # ---------------------------------------------------------------------------
  # Connection
  # ---------------------------------------------------------------------------

  @doc """
  Connects to a MOQ relay at the given URL.

  Options:
  - `:role` — `:both` (default), `:publish`, or `:consume`

  Returns `:ok` immediately. The calling process will receive
  `{:moqx_connected, session}` on success or `{:error, reason}` on failure.
  """
  def connect(url, opts \\ []) when is_binary(url) and is_list(opts) do
    role = opts |> Keyword.get(:role, :both) |> normalize_connect_role!()
    MOQX.Native.connect(url, role)
  end

  @doc """
  Connects a publish-only session.

  This is the preferred mode for sending broadcasts to a relay.
  """
  def connect_publisher(url) when is_binary(url) do
    connect(url, role: :publish)
  end

  @doc """
  Connects a consume-only session.

  This is the preferred mode for subscribing to broadcasts from a relay.
  """
  def connect_subscriber(url) when is_binary(url) do
    connect(url, role: :consume)
  end

  @doc """
  Returns the connection role for a session resource.

  Useful for debugging tests and session wiring.
  """
  def session_role(session) do
    MOQX.Native.session_role(session)
  end

  defp normalize_connect_role!(:both), do: "both"
  defp normalize_connect_role!(:publish), do: "publish"
  defp normalize_connect_role!(:consume), do: "consume"

  defp normalize_connect_role!(role) do
    raise ArgumentError,
          "expected :role to be :both, :publish, or :consume, got: #{inspect(role)}"
  end

  # ---------------------------------------------------------------------------
  # Publish
  # ---------------------------------------------------------------------------

  @doc """
  Creates and announces a broadcast on the session's origin.

  Returns `{:ok, broadcast}` or `{:error, reason}`.
  """
  def publish(session, broadcast_path) when is_binary(broadcast_path) do
    MOQX.Native.publish(session, broadcast_path)
  end

  @doc """
  Creates a named track within a broadcast.

  Returns `{:ok, track}` or `{:error, reason}`.
  """
  def create_track(broadcast, track_name) when is_binary(track_name) do
    MOQX.Native.create_track(broadcast, track_name)
  end

  @doc """
  Writes a single frame as a new group on the track.

  Each call creates a new group containing one frame with the given binary data.
  Returns `:ok` or `{:error, reason}`.
  """
  def write_frame(track, data) when is_binary(data) do
    MOQX.Native.write_frame(track, data)
  end

  @doc """
  Marks a track as finished — no more frames can be written.

  Returns `:ok` or `{:error, reason}`.
  """
  def finish_track(track) do
    MOQX.Native.finish_track(track)
  end

  # ---------------------------------------------------------------------------
  # Subscribe
  # ---------------------------------------------------------------------------

  @doc """
  Subscribes to a track on a remote broadcast.

  Returns `:ok` immediately. The calling process will receive:

  - `{:moqx_subscribed, broadcast_path, track_name}` — subscription is active
  - `{:moqx_frame, group_seq, binary_data}` — a frame of data
  - `{:moqx_track_ended}` — the track has been cleanly finished
  - `{:moqx_error, reason}` — an error occurred
  """
  def subscribe(session, broadcast_path, track_name)
      when is_binary(broadcast_path) and is_binary(track_name) do
    MOQX.Native.subscribe(session, broadcast_path, track_name)
  end
end
