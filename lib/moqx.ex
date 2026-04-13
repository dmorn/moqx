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
        {:moqx_object, ^sub, %MOQX.Object{group_id: 0, payload: payload}} -> payload
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

  @typedoc "Opaque subgroup handle returned by `open_subgroup/3`."
  @opaque subgroup_handle :: reference()

  @typedoc """
  Subgroup id convention, mirroring moqtail-ts:

    * `nil` — first-object-id mode (wire format omits the subgroup id; receivers
      infer it from the first object's id)
    * `0` — fixed-zero mode (wire format has no subgroup id field either; receivers
      default to 0)
    * any positive integer — explicit subgroup id carried on the wire
  """
  @type subgroup_id :: nil | non_neg_integer()

  @typedoc "Object status for `write_object/4` and received objects."
  @type object_status :: :normal | :does_not_exist | :end_of_group | :end_of_track

  @typedoc "Extension header on send or receive. Even types carry varints; odd types carry binaries."
  @type extension :: {non_neg_integer(), non_neg_integer() | binary()}

  @typedoc "Options for `open_subgroup/3`."
  @type open_subgroup_opt ::
          {:subgroup_id, subgroup_id()}
          | {:priority, 0..255}
          | {:end_of_group, boolean()}
          | {:extensions_present, boolean()}

  @typedoc "Options for `write_object/4`."
  @type write_object_opt ::
          {:status, object_status()}
          | {:extensions, [extension()]}

  @typedoc "Options for `close_subgroup/2`."
  @type close_subgroup_opt :: {:end_of_group, boolean()}

  @typedoc "Opaque connect correlation reference returned by `connect/2`."
  @opaque connect_ref :: reference()

  @typedoc "Opaque flush correlation reference returned by `flush_subgroup/1`."
  @opaque flush_ref :: reference()

  @typedoc "Common asynchronous error message families."
  @type async_error_message ::
          {:moqx_request_error, MOQX.RequestError.t()}
          | {:moqx_transport_error, MOQX.TransportError.t()}

  @typedoc "Publish-side subgroup messages delivered to the caller process."
  @type subgroup_message ::
          {:moqx_flush_ok, MOQX.FlushDone.t()}
          | async_error_message()

  @typedoc "Raw CMSF catalog payload bytes (UTF-8 JSON)."
  @type catalog_payload :: binary()

  @typedoc "Connection messages delivered to the caller process."
  @type connect_message ::
          {:moqx_connect_ok, MOQX.ConnectOk.t()}
          | async_error_message()

  @typedoc """
  Opaque subscription handle returned by `subscribe/3,4`.

  Holds the internal state needed to cancel the subscription via
  `unsubscribe/1`. When the last reference to the handle is garbage
  collected, the subscription is automatically canceled.
  """
  @type subscription_handle :: reference()

  @typedoc "Subscription messages delivered to the caller process."
  @type subscribe_message ::
          {:moqx_subscribe_ok, MOQX.SubscribeOk.t()}
          | {:moqx_track_init, MOQX.TrackInit.t()}
          | {:moqx_object, MOQX.ObjectReceived.t()}
          | {:moqx_end_of_group, MOQX.EndOfGroup.t()}
          | {:moqx_publish_done, MOQX.PublishDone.t()}
          | async_error_message()

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
          {:moqx_fetch_ok, MOQX.FetchOk.t()}
          | {:moqx_fetch_object, MOQX.FetchObject.t()}
          | {:moqx_fetch_done, MOQX.FetchDone.t()}
          | async_error_message()

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
  @spec connect(String.t(), [connect_opt()]) ::
          {:ok, connect_ref()} | {:error, MOQX.RequestError.t()}
  def connect(url, opts) when is_binary(url) and is_list(opts) do
    role =
      case Keyword.fetch(opts, :role) do
        {:ok, value} -> normalize_connect_role!(value)
        :error -> raise ArgumentError, "connect/2 requires :role (:publisher or :subscriber)"
      end

    {tls_verify, tls_cacertfile} = opts |> Keyword.get(:tls, []) |> normalize_connect_tls!()

    connect_ref = make_ref()

    case MOQX.Native.connect(url, role, tls_verify, tls_cacertfile, connect_ref) do
      :ok ->
        {:ok, connect_ref}

      {:error, reason} ->
        {:error, %MOQX.RequestError{op: :connect, message: reason, ref: connect_ref}}
    end
  end

  @doc """
  Connects a publisher session.

  Accepts the same options as `connect/2`, except `:role` is fixed to `:publisher`.
  Returns `:ok` immediately. The caller later receives a `t:connect_message/0`.
  """
  @spec connect_publisher(String.t(), Keyword.t()) ::
          {:ok, connect_ref()} | {:error, MOQX.RequestError.t()}
  def connect_publisher(url, opts \\ []) when is_binary(url) and is_list(opts) do
    connect(url, Keyword.put(opts, :role, :publisher))
  end

  @doc """
  Connects a subscriber session.

  Accepts the same options as `connect/2`, except `:role` is fixed to `:subscriber`.
  Returns `:ok` immediately. The caller later receives a `t:connect_message/0`.
  """
  @spec connect_subscriber(String.t(), Keyword.t()) ::
          {:ok, connect_ref()} | {:error, MOQX.RequestError.t()}
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

  Convenience wrapper over the subgroup primitives: opens a subgroup with
  subgroup id `0`, writes one object, closes the stream. Each call creates the
  next group in that track.

  Subscribers receive `{:moqx_object, handle, %MOQX.Object{group_id: group_seq,
  subgroup_id: 0, object_id: 0, status: :normal, payload: data}}`.

  For fine-grained control over subgroups, priority, extensions, end-of-group
  markers, or multiple objects per group use `open_subgroup/3` +
  `write_object/4` + `close_subgroup/2`.
  """
  @spec write_frame(track(), binary()) :: :ok | {:error, String.t()}
  def write_frame(track, data) when is_binary(data) do
    group_id = MOQX.Native.track_next_group_id(track)

    with {:ok, sg} <- open_subgroup(track, group_id, subgroup_id: 0, priority: 0),
         :ok <- write_object(sg, 0, data) do
      close_subgroup(sg)
    end
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
  # Subgroup primitives
  # ---------------------------------------------------------------------------

  @doc """
  Opens a subgroup on a publishing track.

  Returns `{:ok, handle}` synchronously (the QUIC uni-stream is opened
  asynchronously). Any async failure during stream open, write, flush, or close
  arrives later on the caller process as `{:moqx_error, handle, reason}`.

  `group_id` is an explicit non-negative integer chosen by the caller. Multiple
  calls with the same `group_id` but different `:subgroup_id` open parallel
  subgroup streams within the same group.

  ## Options

    * `:subgroup_id` — `nil | 0 | pos_integer` (default `0`). `nil` selects the
      first-object-id mode (wire omits the subgroup id; receivers infer it from
      the first object). `0` selects the fixed-zero mode. Any positive integer
      is carried explicitly on the wire.

    * `:priority` — `0..255` publisher priority (default `0`).

    * `:end_of_group` — when `true`, the chosen subgroup header variant signals
      that an end-of-group marker will be emitted. You must call
      `close_subgroup(handle, end_of_group: true)` to actually write the marker.
      (default `false`)

    * `:extensions_present` — when `true`, the subgroup header declares that
      every object on this stream carries an extensions block (possibly empty).
      Required if any `write_object/4` on this subgroup will pass
      `:extensions`. (default `false`)
  """
  @spec open_subgroup(track(), non_neg_integer(), [open_subgroup_opt()]) ::
          {:ok, subgroup_handle()} | {:error, String.t()}
  def open_subgroup(track, group_id, opts \\ [])
      when is_integer(group_id) and group_id >= 0 and is_list(opts) do
    subgroup_id = opts |> Keyword.get(:subgroup_id, 0) |> normalize_subgroup_id!()
    priority = opts |> Keyword.get(:priority, 0) |> normalize_priority!()
    end_of_group = opts |> Keyword.get(:end_of_group, false) |> normalize_boolean!(:end_of_group)

    extensions_present =
      opts |> Keyword.get(:extensions_present, false) |> normalize_boolean!(:extensions_present)

    validate_open_subgroup_opts!(opts)

    case MOQX.Native.open_subgroup(
           track,
           group_id,
           subgroup_id,
           priority,
           end_of_group,
           extensions_present
         ) do
      {:ok, handle} -> {:ok, handle}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Writes one object to an open subgroup.

  Returns `:ok` after the bytes are queued to the underlying Tokio runtime.
  Any async failure arrives as `{:moqx_error, handle, reason}`.

  `object_id` must be strictly greater than the previous object's id on the
  same subgroup. Pick `0` for the first object and increment monotonically.

  ## Options

    * `:status` — one of `:normal | :does_not_exist | :end_of_group |
      :end_of_track` (default `:normal`). For `:normal`, the `payload` is sent
      as-is. For marker statuses, the payload is ignored on the wire (the
      object is a zero-length status marker).

    * `:extensions` — per-object extension headers (default `[]`).
  """
  @spec write_object(subgroup_handle(), non_neg_integer(), binary(), [write_object_opt()]) ::
          :ok | {:error, String.t()}
  def write_object(subgroup, object_id, payload, opts \\ [])
      when is_reference(subgroup) and is_integer(object_id) and object_id >= 0 and
             is_binary(payload) and is_list(opts) do
    status = opts |> Keyword.get(:status, :normal) |> normalize_status!()
    extensions = opts |> Keyword.get(:extensions, []) |> normalize_extensions!()

    validate_write_object_opts!(opts)

    MOQX.Native.write_object(subgroup, object_id, payload, extensions, status)
  end

  @doc """
  Closes a subgroup and finishes its underlying uni-stream.

  ## Options

    * `:end_of_group` — when `true`, emits an end-of-group marker object before
      finishing the stream. Requires the subgroup to have been opened with
      `end_of_group: true` (otherwise the on-wire header variant would be
      inconsistent).

  Dropping the handle (garbage collection) triggers a plain close without the
  end-of-group marker, matching the semantics of `close_subgroup(handle,
  end_of_group: false)`.
  """
  @spec close_subgroup(subgroup_handle(), [close_subgroup_opt()]) :: :ok | {:error, String.t()}
  def close_subgroup(subgroup, opts \\ []) when is_reference(subgroup) and is_list(opts) do
    end_of_group = opts |> Keyword.get(:end_of_group, false) |> normalize_boolean!(:end_of_group)

    validate_close_subgroup_opts!(opts)

    MOQX.Native.close_subgroup(subgroup, end_of_group)
  end

  @doc """
  Requests a flush of the subgroup's underlying QUIC stream.

  Returns `:ok` immediately. The caller later receives
  `{:moqx_flushed, handle}` when the flush completes, or
  `{:moqx_error, handle, reason}` on failure.
  """
  @spec flush_subgroup(subgroup_handle()) ::
          {:ok, flush_ref()} | {:error, MOQX.RequestError.t()}
  def flush_subgroup(subgroup) when is_reference(subgroup) do
    flush_ref = make_ref()

    case MOQX.Native.flush_subgroup(subgroup, flush_ref) do
      :ok ->
        {:ok, flush_ref}

      {:error, reason} ->
        {:error,
         %MOQX.RequestError{
           op: :flush_subgroup,
           message: reason,
           ref: flush_ref,
           handle: subgroup
         }}
    end
  end

  defp normalize_subgroup_id!(nil), do: nil

  defp normalize_subgroup_id!(id) when is_integer(id) and id >= 0, do: id

  defp normalize_subgroup_id!(id) do
    raise ArgumentError,
          "expected :subgroup_id to be nil or a non-negative integer, got: #{inspect(id)}"
  end

  defp normalize_priority!(p) when is_integer(p) and p in 0..255, do: p

  defp normalize_priority!(p) do
    raise ArgumentError, "expected :priority to be an integer in 0..255, got: #{inspect(p)}"
  end

  defp normalize_boolean!(true, _name), do: true
  defp normalize_boolean!(false, _name), do: false

  defp normalize_boolean!(other, name) do
    raise ArgumentError, "expected #{inspect(name)} to be a boolean, got: #{inspect(other)}"
  end

  defp normalize_status!(s) when s in [:normal, :does_not_exist, :end_of_group, :end_of_track],
    do: s

  defp normalize_status!(s) do
    raise ArgumentError,
          "expected :status to be one of :normal, :does_not_exist, :end_of_group, :end_of_track, got: #{inspect(s)}"
  end

  defp normalize_extensions!(exts) when is_list(exts) do
    Enum.map(exts, &normalize_extension!/1)
  end

  defp normalize_extensions!(other) do
    raise ArgumentError, "expected :extensions to be a list, got: #{inspect(other)}"
  end

  defp normalize_extension!({type, value}) when is_integer(type) and type >= 0 do
    normalize_extension_value!(type, value)
  end

  defp normalize_extension!(other) do
    raise ArgumentError,
          "expected extension to be {non_neg_integer, non_neg_integer | binary}, got: #{inspect(other)}"
  end

  defp normalize_extension_value!(type, value) when rem(type, 2) == 0 do
    if is_integer(value) and value >= 0 do
      {type, value}
    else
      raise ArgumentError,
            "extension type #{type} is even (varint) but value is not a non-negative integer: #{inspect(value)}"
    end
  end

  defp normalize_extension_value!(type, value) do
    if is_binary(value) do
      {type, value}
    else
      raise ArgumentError,
            "extension type #{type} is odd (bytes) but value is not a binary: #{inspect(value)}"
    end
  end

  defp validate_open_subgroup_opts!(opts) do
    allowed = [:subgroup_id, :priority, :end_of_group, :extensions_present]

    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unexpected open_subgroup option #{inspect(key)}"
    end
  end

  defp validate_write_object_opts!(opts) do
    allowed = [:status, :extensions]

    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unexpected write_object option #{inspect(key)}"
    end
  end

  defp validate_close_subgroup_opts!(opts) do
    allowed = [:end_of_group]

    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unexpected close_subgroup option #{inspect(key)}"
    end
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
  - `{:moqx_object, handle, %MOQX.Object{}}` for each delivered object
  - `{:moqx_end_of_group, handle, group_id, subgroup_id}` when a subgroup
    signals end-of-group (via header flag, status-0x3 marker object, or both)
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
          {:ok, subscription_handle()} | {:error, MOQX.RequestError.t()}
  def subscribe(session, broadcast_path, track_name)
      when is_binary(broadcast_path) and is_binary(track_name) do
    subscribe(session, broadcast_path, track_name, [])
  end

  @doc """
  Same as `subscribe/3`, with explicit subscription options.
  """
  @spec subscribe(session(), String.t(), String.t(), [subscribe_opt()]) ::
          {:ok, subscription_handle()} | {:error, MOQX.RequestError.t()}
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
      {:error, reason} ->
        {:error,
         %MOQX.RequestError{
           op: :subscribe,
           message: reason
         }}

      handle ->
        {:ok, handle}
    end
  end

  @doc """
  Subscribes using a `%MOQX.Catalog.Track{}`.

  This convenience helper derives `track_name`, `init_data`, and `track_meta`
  from the provided track and forwards to `subscribe/4`.
  """
  @spec subscribe_track(session(), String.t(), Track.t()) ::
          {:ok, subscription_handle()} | {:error, MOQX.RequestError.t()}
  def subscribe_track(session, broadcast_path, %Track{} = track)
      when is_binary(broadcast_path) do
    subscribe_track(session, broadcast_path, track, [])
  end

  @doc """
  Same as `subscribe_track/3`, with explicit options.

  `:track` is not accepted here (it is implied by the `track` argument).
  """
  @spec subscribe_track(session(), String.t(), Track.t(), [subscribe_opt()]) ::
          {:ok, subscription_handle()} | {:error, MOQX.RequestError.t()}
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
          {:ok, fetch_ref()} | {:error, MOQX.RequestError.t()}
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
          :ok ->
            {:ok, ref}

          {:error, reason} ->
            {:error,
             %MOQX.RequestError{
               op: :fetch,
               message: reason,
               ref: ref
             }}
        end

      :publisher ->
        {:error,
         %MOQX.RequestError{
           op: :fetch,
           message: "fetch requires a subscriber session"
         }}
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
  @spec fetch_catalog(session(), Keyword.t()) ::
          {:ok, fetch_ref()} | {:error, MOQX.RequestError.t()}
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
      {:moqx_fetch_ok, %MOQX.FetchOk{ref: ^ref}} ->
        await_catalog_loop(ref, acc, timeout)

      {:moqx_fetch_object, %MOQX.FetchObject{ref: ^ref, payload: payload}} ->
        await_catalog_loop(ref, [acc | [payload]], timeout)

      {:moqx_fetch_done, %MOQX.FetchDone{ref: ^ref}} ->
        MOQX.Catalog.decode(IO.iodata_to_binary(acc))

      {:moqx_request_error, %MOQX.RequestError{op: :fetch, ref: ^ref, message: reason}} ->
        {:error, reason}

      {:moqx_transport_error, %MOQX.TransportError{op: :fetch, ref: ^ref, message: reason}} ->
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
