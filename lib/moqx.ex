defmodule MOQX do
  alias MOQX.Catalog.Track

  @moduledoc """
  Elixir bindings for Media over QUIC (MOQ) via Rustler NIFs on top of
  `moqtail-rs`.

  `moqx` intentionally exposes a narrow client-only contract:

  - split roles only: publisher sessions publish and subscriber sessions subscribe
  - WebTransport (Draft 14) only
  - minimal client TLS controls with verification on by default
  - relay auth carried in the connect URL query as `?jwt=...`
  - rooted relay URLs whose path must match the token `root`

  Relay/server listener APIs remain out of scope.

  `MOQX` exposes one clear, supported flow:

  1. connect a publisher session with `connect_publisher/1`
  2. connect a subscriber session with `connect_subscriber/1`
  3. publish a broadcast with `publish/2`
  4. optionally publish catalog objects with `publish_catalog/2` and `update_catalog/2`
  5. create one or more tracks with `create_track/2`
  6. send frames with `write_frame/2`
  7. subscribe with `subscribe/3` or `subscribe_track/3`
  8. fetch raw track objects with `fetch/4` or `fetch_catalog/2` (subscriber only)
  9. decode a CMSF catalog with `MOQX.Catalog.decode/1` and discover tracks

  Connection and subscription are asynchronous:

  - `connect_publisher/1`, `connect_subscriber/1`, and `connect/2` return `:ok` immediately
  - the caller later receives exactly one connect result: `{:moqx_connected, session}` or `{:error, reason}`
  - `subscribe/3` returns `{:ok, handle}` immediately; call `unsubscribe/1` to cancel
  - the caller later receives subscription lifecycle messages
  - immediate misuse errors are returned synchronously as `{:error, reason}`
  - asynchronous relay/runtime failures arrive later as process messages

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

      {:ok, sub} = MOQX.subscribe(subscriber, "anon/demo", "video")

      receive do
        {:moqx_subscribed, ^sub, "anon/demo", "video"} -> :ok
      end

      receive do
        {:moqx_track_init, ^sub, _init_data, _track_meta} -> :ok
      end

      receive do
        {:moqx_frame, ^sub, 0, payload} -> payload
      end

      :ok = MOQX.unsubscribe(sub)

      receive do
        {:moqx_track_ended, ^sub} -> :ok
      end

      # Fetch and decode a remote catalog
      {:ok, ref} = MOQX.fetch_catalog(subscriber)
      {:ok, catalog} = MOQX.await_catalog(ref)

      catalog
      |> MOQX.Catalog.video_tracks()
      |> Enum.map(& &1.name)

  Broadcast announcement is lazy: a broadcast becomes visible to subscribers
  on the first successful `write_frame/2` for any track in that broadcast.

  TLS verification is enabled by default. For local development against a
  self-signed relay, either configure a trusted local certificate chain or opt
  into `tls: [verify: :insecure]` explicitly. Custom trust roots can be passed
  with `tls: [cacertfile: "/path/to/rootCA.pem"]`.
  """

  @typedoc "Publisher or subscriber session role."
  @type role :: :publisher | :subscriber

  @typedoc ~S|MOQ protocol version string, e.g. `"moq-transport-14"`.|
  @type version :: String.t()

  @typedoc "TLS verification mode for relay connections."
  @type tls_verify :: :verify_peer | :insecure

  @typedoc "TLS connect options."
  @type tls_opt :: {:verify, tls_verify()} | {:cacertfile, String.t()}

  @typedoc "Opaque session resource returned in `{:moqx_connected, session}`."
  @opaque session :: reference()

  @typedoc "Opaque broadcast resource returned by `publish/2`."
  @opaque broadcast :: reference()

  @typedoc "Opaque track resource returned by `create_track/2`."
  @opaque track :: reference()

  @typedoc "Raw CMSF catalog payload bytes (UTF-8 JSON)."
  @type catalog_payload :: binary()

  @typedoc "Connection result delivered to the caller process."
  @type connect_message :: {:moqx_connected, session()} | {:error, String.t()}

  @typedoc """
  Opaque subscription handle returned by `subscribe/3,4`.

  Holds the internal state needed to cancel the subscription via
  `unsubscribe/1`. When the last reference to the handle is garbage
  collected, the subscription is automatically canceled.
  """
  @type subscription_handle :: reference()

  @typedoc "Subscription messages delivered to the caller process."
  @type subscribe_message ::
          {:moqx_subscribed, subscription_handle(), String.t(), String.t()}
          | {:moqx_track_init, subscription_handle(), binary() | nil, map()}
          | {:moqx_frame, subscription_handle(), non_neg_integer(), binary()}
          | {:moqx_track_ended, subscription_handle()}
          | {:moqx_error, subscription_handle(), String.t()}

  @typedoc "Subscribe options accepted by `subscribe/4` and `subscribe_track/4`."
  @type subscribe_opt ::
          {:delivery_timeout_ms, non_neg_integer()}
          | {:init_data, binary()}
          | {:track_meta, map()}
          | {:track, Track.t()}

  @typedoc "Opaque fetch correlation reference returned by `fetch/4`."
  @type fetch_ref :: reference()

  @typedoc "Requested group ordering for fetch delivery."
  @type fetch_group_order :: :original | :ascending | :descending

  @typedoc "Fetch start or end location as `{group_id, object_id}`."
  @type fetch_location :: {non_neg_integer(), non_neg_integer()}

  @typedoc "Fetch options accepted by `fetch/4`."
  @type fetch_opt ::
          {:priority, 0..255}
          | {:group_order, fetch_group_order()}
          | {:start, fetch_location()}
          | {:end, fetch_location()}

  @typedoc "Fetch lifecycle messages delivered to the caller process."
  @type fetch_message ::
          {:moqx_fetch_started, fetch_ref(), String.t(), String.t()}
          | {:moqx_fetch_object, fetch_ref(), non_neg_integer(), non_neg_integer(), binary()}
          | {:moqx_fetch_done, fetch_ref()}
          | {:moqx_fetch_error, fetch_ref(), String.t()}

  @type connect_opt ::
          {:role, role()}
          | {:tls, [tls_opt()]}

  @doc """
  Connects to a relay with an explicit role.

  Prefer `connect_publisher/2` and `connect_subscriber/2` unless you need to
  select the role dynamically.

  Supported options:

  - `:role` - required, `:publisher` or `:subscriber`
  - `:tls` - optional TLS controls:
    - `verify: :verify_peer | :insecure` (defaults to `:verify_peer`)
    - `cacertfile: "/path/to/rootCA.pem"` to trust a custom root CA PEM

  `connect/2` is the dynamic-role entrypoint only. There is no supported merged
  publisher/subscriber session mode, and listener/server APIs remain out of scope.

  Returns `:ok` immediately. The caller later receives a `t:connect_message/0`.
  """
  @spec connect(String.t(), [connect_opt()]) :: :ok | {:error, String.t()}
  def connect(url, opts) when is_binary(url) and is_list(opts) do
    role =
      case Keyword.fetch(opts, :role) do
        {:ok, value} -> normalize_connect_role!(value)
        :error -> raise ArgumentError, "connect/2 requires :role (:publisher or :subscriber)"
      end

    {tls_verify, tls_cacertfile} = opts |> Keyword.get(:tls, []) |> normalize_connect_tls!()

    MOQX.Native.connect(url, role, tls_verify, tls_cacertfile)
  end

  @doc """
  Connects a publisher session.

  Accepts the same options as `connect/2`, except `:role` is fixed to `:publisher`.
  Returns `:ok` immediately. The caller later receives a `t:connect_message/0`.
  """
  @spec connect_publisher(String.t(), Keyword.t()) :: :ok | {:error, String.t()}
  def connect_publisher(url, opts \\ []) when is_binary(url) and is_list(opts) do
    connect(url, Keyword.put(opts, :role, :publisher))
  end

  @doc """
  Connects a subscriber session.

  Accepts the same options as `connect/2`, except `:role` is fixed to `:subscriber`.
  Returns `:ok` immediately. The caller later receives a `t:connect_message/0`.
  """
  @spec connect_subscriber(String.t(), Keyword.t()) :: :ok | {:error, String.t()}
  def connect_subscriber(url, opts \\ []) when is_binary(url) and is_list(opts) do
    connect(url, Keyword.put(opts, :role, :subscriber))
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

  @doc false
  @spec session_version(session()) :: version()
  def session_version(session) do
    MOQX.Native.session_version(session)
  end

  defp normalize_connect_role!(:publisher), do: "publisher"
  defp normalize_connect_role!(:subscriber), do: "subscriber"

  defp normalize_connect_role!(role) do
    raise ArgumentError,
          "expected :role to be :publisher or :subscriber, got: #{inspect(role)}"
  end

  defp normalize_connect_tls!(opts) when is_list(opts) do
    verify = opts |> Keyword.get(:verify, :verify_peer) |> normalize_connect_tls_verify!()
    cacertfile = opts |> Keyword.get(:cacertfile) |> normalize_connect_tls_cacertfile()

    allowed_keys = [:verify, :cacertfile]

    case Keyword.keys(opts) -- allowed_keys do
      [] -> {verify, cacertfile}
      [key | _] -> raise ArgumentError, "unexpected :tls option #{inspect(key)}"
    end
  end

  defp normalize_connect_tls!(other) do
    raise ArgumentError,
          "expected :tls to be a keyword list, got: #{inspect(other)}"
  end

  defp normalize_connect_tls_verify!(:verify_peer), do: "verify_peer"
  defp normalize_connect_tls_verify!(:insecure), do: "insecure"

  defp normalize_connect_tls_verify!(verify) do
    raise ArgumentError,
          "expected :tls :verify to be :verify_peer or :insecure, got: #{inspect(verify)}"
  end

  defp normalize_connect_tls_cacertfile(nil), do: nil
  defp normalize_connect_tls_cacertfile(path) when is_binary(path), do: path

  defp normalize_connect_tls_cacertfile(path) do
    raise ArgumentError,
          "expected :tls :cacertfile to be a string path, got: #{inspect(path)}"
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
  Creates and publishes the initial catalog object on the `"catalog"` track.

  This convenience helper composes `create_track/2` and `update_catalog/2`:

      {:ok, catalog_track} = MOQX.publish_catalog(broadcast, catalog_json)

  Returns `{:ok, catalog_track}` when both steps succeed.
  """
  @spec publish_catalog(broadcast(), catalog_payload()) :: {:ok, track()} | {:error, String.t()}
  def publish_catalog(broadcast, catalog_payload) when is_binary(catalog_payload) do
    with {:ok, catalog_track} <- create_track(broadcast, "catalog"),
         :ok <- update_catalog(catalog_track, catalog_payload) do
      {:ok, catalog_track}
    end
  end

  @doc """
  Writes one catalog object to an existing catalog track.

  Use this to push catalog updates after the initial `publish_catalog/2` call.
  """
  @spec update_catalog(track(), catalog_payload()) :: :ok | {:error, String.t()}
  def update_catalog(track, catalog_payload) when is_binary(catalog_payload) do
    write_frame(track, catalog_payload)
  end

  @doc """
  Writes one frame to a track.

  Each call creates the next group in that track. Group sequence numbers are
  delivered to subscribers in `{:moqx_frame, handle, group_seq, payload}` messages.
  """
  @spec write_frame(track(), binary()) :: :ok | {:error, String.t()}
  def write_frame(track, data) when is_binary(data) do
    MOQX.Native.write_frame(track, data)
  end

  @doc """
  Finishes a track.

  Subscribers receive `{:moqx_track_ended, handle}` after the track is fully consumed.
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

  Returns `{:ok, handle}` immediately. The caller later receives a
  `t:subscribe_message/0` stream correlated by that `handle`:

  - `{:moqx_subscribed, handle, broadcast_path, track_name}` when active
  - `{:moqx_track_init, handle, init_data, track_meta}` once per subscription
  - `{:moqx_frame, handle, group_seq, payload}` for each frame object
  - `{:moqx_track_ended, handle}` when the track finishes cleanly or after
    `unsubscribe/1` is acknowledged by the relay
  - `{:moqx_error, handle, reason}` for asynchronous runtime failures

  Supported options:

  - `:delivery_timeout_ms` -- MOQT DELIVERY TIMEOUT (parameter type `0x02`) in milliseconds
  - `:init_data` -- binary init segment/configuration to surface in `:moqx_track_init`
  - `:track_meta` -- map surfaced in `:moqx_track_init`
  - `:track` -- `%MOQX.Catalog.Track{}` convenience; fills `:init_data` and `:track_meta`

  Misuse errors, such as calling this with a publisher session, are returned as
  `{:error, reason}` immediately.
  """
  @spec subscribe(session(), String.t(), String.t()) ::
          {:ok, subscription_handle()} | {:error, String.t()}
  def subscribe(session, broadcast_path, track_name)
      when is_binary(broadcast_path) and is_binary(track_name) do
    subscribe(session, broadcast_path, track_name, [])
  end

  @doc """
  Same as `subscribe/3`, with explicit subscription options.
  """
  @spec subscribe(session(), String.t(), String.t(), [subscribe_opt()]) ::
          {:ok, subscription_handle()} | {:error, String.t()}
  def subscribe(session, broadcast_path, track_name, opts)
      when is_binary(broadcast_path) and is_binary(track_name) and is_list(opts) do
    delivery_timeout_ms =
      opts |> Keyword.get(:delivery_timeout_ms) |> normalize_delivery_timeout_ms!()

    {init_data, track_meta} = normalize_subscribe_track_payload!(opts)

    validate_subscribe_opts_keys!(opts)

    case MOQX.Native.subscribe(
           session,
           broadcast_path,
           track_name,
           delivery_timeout_ms,
           init_data,
           track_meta
         ) do
      {:error, _reason} = error -> error
      handle -> {:ok, handle}
    end
  end

  @doc """
  Subscribes using a `%MOQX.Catalog.Track{}`.

  This convenience helper derives `track_name`, `init_data`, and `track_meta`
  from the provided track and forwards to `subscribe/4`.
  """
  @spec subscribe_track(session(), String.t(), Track.t()) ::
          {:ok, subscription_handle()} | {:error, String.t()}
  def subscribe_track(session, broadcast_path, %Track{} = track)
      when is_binary(broadcast_path) do
    subscribe_track(session, broadcast_path, track, [])
  end

  @doc """
  Same as `subscribe_track/3`, with explicit options.

  `:track` is not accepted here (it is implied by the `track` argument).
  """
  @spec subscribe_track(session(), String.t(), Track.t(), [subscribe_opt()]) ::
          {:ok, subscription_handle()} | {:error, String.t()}
  def subscribe_track(session, broadcast_path, %Track{} = track, opts)
      when is_binary(broadcast_path) and is_list(opts) do
    if Keyword.has_key?(opts, :track) do
      raise ArgumentError, "subscribe_track/4 does not accept :track in opts"
    end

    subscribe(session, broadcast_path, track.name, Keyword.put(opts, :track, track))
  end

  @doc """
  Cancels an active track subscription.

  Sends MOQ `Unsubscribe` to the relay and removes local subscription state.
  The caller may still receive `{:moqx_track_ended, handle}` once the relay
  acknowledges with `PublishDone`.

  Idempotent: repeated calls (and calls after the subscription has already
  ended) return `:ok` without sending further control traffic.

  Dropping the handle (garbage collection) triggers the same cleanup, so
  short-lived subscribing processes do not need to call this explicitly.
  """
  @spec unsubscribe(subscription_handle()) :: :ok
  def unsubscribe(handle) when is_reference(handle) do
    MOQX.Native.unsubscribe(handle)
  end

  defp validate_subscribe_opts_keys!(opts) do
    allowed_keys = [:delivery_timeout_ms, :init_data, :track_meta, :track]

    case Keyword.keys(opts) -- allowed_keys do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unexpected subscribe option #{inspect(key)}"
    end
  end

  defp normalize_subscribe_track_payload!(opts) do
    init_data = opts |> Keyword.get(:init_data) |> normalize_subscribe_init_data!()
    track_meta = opts |> Keyword.get(:track_meta, %{}) |> normalize_subscribe_track_meta!()

    case Keyword.get(opts, :track) do
      nil ->
        {init_data, track_meta}

      track ->
        normalize_subscribe_track_payload_from_track!(track, init_data, track_meta)
    end
  end

  defp normalize_subscribe_track_payload_from_track!(%Track{} = track, init_data, track_meta) do
    normalized_init_data = init_data || track.init_data

    normalized_track_meta =
      case track_meta do
        %{} = map when map_size(map) == 0 -> Track.describe(track)
        map -> map
      end

    {normalized_init_data, normalized_track_meta}
  end

  defp normalize_subscribe_track_payload_from_track!(track, _init_data, _track_meta) do
    raise ArgumentError,
          "expected :track to be a %MOQX.Catalog.Track{}, got: #{inspect(track)}"
  end

  defp normalize_subscribe_init_data!(nil), do: nil
  defp normalize_subscribe_init_data!(init_data) when is_binary(init_data), do: init_data

  defp normalize_subscribe_init_data!(init_data) do
    raise ArgumentError,
          "expected :init_data to be a binary, got: #{inspect(init_data)}"
  end

  defp normalize_subscribe_track_meta!(track_meta) when is_map(track_meta), do: track_meta

  defp normalize_subscribe_track_meta!(track_meta) do
    raise ArgumentError,
          "expected :track_meta to be a map, got: #{inspect(track_meta)}"
  end

  defp normalize_delivery_timeout_ms!(nil), do: nil

  defp normalize_delivery_timeout_ms!(delivery_timeout_ms)
       when is_integer(delivery_timeout_ms) and delivery_timeout_ms >= 0,
       do: delivery_timeout_ms

  defp normalize_delivery_timeout_ms!(delivery_timeout_ms) do
    raise ArgumentError,
          "expected :delivery_timeout_ms to be a non-negative integer, got: #{inspect(delivery_timeout_ms)}"
  end

  # ---------------------------------------------------------------------------
  # Fetch
  # ---------------------------------------------------------------------------

  @doc """
  Submits a raw fetch request on a subscriber session.

  Returns `{:ok, ref}` immediately after the request is accepted for submission.
  The caller later receives a `t:fetch_message/0` stream correlated by `ref`.

  Misuse errors, such as calling this with a publisher session, are returned as
  `{:error, reason}` immediately.
  """
  @spec fetch(session(), String.t(), String.t(), [fetch_opt()]) ::
          {:ok, fetch_ref()} | {:error, String.t()}
  def fetch(session, namespace, track_name, opts \\ [])
      when is_binary(namespace) and is_binary(track_name) and is_list(opts) do
    priority = opts |> Keyword.get(:priority, 0) |> normalize_fetch_priority!()
    group_order = opts |> Keyword.get(:group_order, :original) |> normalize_fetch_group_order!()
    start = opts |> Keyword.get(:start, {0, 0}) |> normalize_fetch_location!(:start)
    end_location = opts |> Keyword.get(:end) |> normalize_fetch_end!()

    validate_fetch_opts_keys!(opts)
    validate_fetch_range!(start, end_location)

    case session_role(session) do
      :subscriber ->
        ref = make_ref()

        case MOQX.Native.fetch(
               session,
               ref,
               namespace,
               track_name,
               priority,
               group_order,
               start,
               end_location
             ) do
          :ok -> {:ok, ref}
          {:error, _reason} = error -> error
        end

      :publisher ->
        {:error, "fetch requires a subscriber session"}
    end
  end

  @doc """
  Fetches the raw catalog track bytes.

  This is a thin wrapper over `fetch/4` with catalog defaults:

  - namespace: `"moqtail"`
  - track name: `"catalog"`
  - priority: `0`
  - group order: `:original`
  - start: `{0, 0}`
  - end: `{0, 1}`
  """
  @spec fetch_catalog(session(), Keyword.t()) :: {:ok, fetch_ref()} | {:error, String.t()}
  def fetch_catalog(session, opts \\ []) when is_list(opts) do
    namespace = opts |> Keyword.get(:namespace, "moqtail") |> normalize_fetch_namespace!()

    fetch_opts =
      opts
      |> Keyword.delete(:namespace)
      |> Keyword.put_new(:priority, 0)
      |> Keyword.put_new(:group_order, :original)
      |> Keyword.put_new(:start, {0, 0})
      |> Keyword.put_new(:end, {0, 1})

    fetch(session, namespace, "catalog", fetch_opts)
  end

  @doc """
  Collects fetch messages for `ref` and decodes the payload as a CMSF catalog.

  Blocks the caller until all objects are received, then concatenates the
  payloads and passes them to `MOQX.Catalog.decode/1`.

  Returns `{:ok, catalog}` on success, `{:error, reason}` on fetch failure
  or decode failure, and `{:error, "timeout"}` if no terminal message arrives
  within `timeout` milliseconds.

  ## Example

      {:ok, ref} = MOQX.fetch_catalog(subscriber, namespace: "moqtail")
      {:ok, catalog} = MOQX.await_catalog(ref)
  """
  @spec await_catalog(fetch_ref(), timeout()) ::
          {:ok, MOQX.Catalog.t()} | {:error, String.t()}
  def await_catalog(ref, timeout \\ 5_000) when is_reference(ref) do
    await_catalog_loop(ref, [], timeout)
  end

  defp await_catalog_loop(ref, acc, timeout) do
    receive do
      {:moqx_fetch_started, ^ref, _ns, _track} ->
        await_catalog_loop(ref, acc, timeout)

      {:moqx_fetch_object, ^ref, _group, _object, payload} ->
        await_catalog_loop(ref, [acc | [payload]], timeout)

      {:moqx_fetch_done, ^ref} ->
        MOQX.Catalog.decode(IO.iodata_to_binary(acc))

      {:moqx_fetch_error, ^ref, reason} ->
        {:error, reason}
    after
      timeout -> {:error, "timeout"}
    end
  end

  defp validate_fetch_opts_keys!(opts) do
    allowed_keys = [:priority, :group_order, :start, :end]

    case Keyword.keys(opts) -- allowed_keys do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unexpected fetch option #{inspect(key)}"
    end
  end

  defp normalize_fetch_namespace!(namespace) when is_binary(namespace), do: namespace

  defp normalize_fetch_namespace!(namespace) do
    raise ArgumentError,
          "expected catalog :namespace to be a string, got: #{inspect(namespace)}"
  end

  defp normalize_fetch_priority!(priority) when is_integer(priority) and priority in 0..255,
    do: priority

  defp normalize_fetch_priority!(priority) do
    raise ArgumentError,
          "expected :priority to be an integer in 0..255, got: #{inspect(priority)}"
  end

  defp normalize_fetch_group_order!(:original), do: "original"
  defp normalize_fetch_group_order!(:ascending), do: "ascending"
  defp normalize_fetch_group_order!(:descending), do: "descending"

  defp normalize_fetch_group_order!(group_order) do
    raise ArgumentError,
          "expected :group_order to be :original, :ascending, or :descending, got: #{inspect(group_order)}"
  end

  defp normalize_fetch_location!({group_id, object_id}, _name)
       when is_integer(group_id) and group_id >= 0 and is_integer(object_id) and object_id >= 0 do
    {group_id, object_id}
  end

  defp normalize_fetch_location!(location, name) do
    raise ArgumentError,
          "expected #{inspect(name)} to be {group_id, object_id} with non-negative integers, got: #{inspect(location)}"
  end

  defp normalize_fetch_end!(nil), do: nil
  defp normalize_fetch_end!(location), do: normalize_fetch_location!(location, :end)

  defp validate_fetch_range!(_start, nil), do: :ok

  defp validate_fetch_range!({start_group, start_object}, {end_group, end_object})
       when end_group > start_group or
              (end_group == start_group and end_object >= start_object),
       do: :ok

  defp validate_fetch_range!(start, end_location) do
    raise ArgumentError,
          "expected :end to be greater than or equal to :start, got: start=#{inspect(start)}, end=#{inspect(end_location)}"
  end
end
