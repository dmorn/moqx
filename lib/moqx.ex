defmodule MOQX do
  @moduledoc """
  Elixir bindings for Media over QUIC (MOQ) via Rustler NIFs on top of
  `moq-lite` / `moq-native`.

  `moqx` intentionally exposes a narrow client-only contract:

  - split roles only: publisher sessions publish and subscriber sessions subscribe
  - Quinn-backed connections only
  - transports limited to `:auto`, `:raw_quic`, `:webtransport`, and `:websocket`
  - minimal client TLS controls with verification on by default
  - relay auth carried in the connect URL query as `?jwt=...`
  - rooted relay URLs whose path must match the token `root`

  Relay/server listener APIs remain out of scope.

  `MOQX` exposes one clear, supported flow:

  1. connect a publisher session with `connect_publisher/1`
  2. connect a subscriber session with `connect_subscriber/1`
  3. publish a broadcast with `publish/2`
  4. create one or more tracks with `create_track/2`
  5. send frames with `write_frame/2`
  6. subscribe with `subscribe/3`
  7. fetch raw track objects with `fetch/4` or `fetch_catalog/2` (subscriber only)

  Connection and subscription are asynchronous:

  - `connect_publisher/1`, `connect_subscriber/1`, and `connect/2` return `:ok` immediately
  - the caller later receives exactly one connect result: `{:moqx_connected, session}` or `{:error, reason}`
  - `subscribe/3` returns `:ok` immediately
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

      :ok = MOQX.subscribe(subscriber, "anon/demo", "video")

      receive do
        {:moqx_subscribed, "anon/demo", "video"} -> :ok
      end

      receive do
        {:moqx_frame, 0, payload} -> payload
      end

      receive do
        :moqx_track_ended -> :ok
      end

      # Fetch raw catalog bytes from the relay
      {:ok, ref} = MOQX.fetch_catalog(subscriber)

      receive do
        {:moqx_fetch_started, ^ref, _ns, _track} -> :ok
      end

      catalog_bytes =
        receive do
          {:moqx_fetch_object, ^ref, _gid, _oid, payload} -> payload
        end

      receive do
        {:moqx_fetch_done, ^ref} -> :ok
      end

  Broadcast announcement is lazy: a broadcast becomes visible to subscribers
  on the first successful `write_frame/2` for any track in that broadcast.

  TLS verification is enabled by default. For local development against a
  self-signed relay, either configure a trusted local certificate chain or opt
  into `tls: [verify: :insecure]` explicitly. Custom trust roots can be passed
  with `tls: [cacertfile: "/path/to/rootCA.pem"]`.
  """

  @typedoc "Publisher or subscriber session role."
  @type role :: :publisher | :subscriber

  @typedoc "Compiled native QUIC backend. Today `moqx` intentionally supports only Quinn."
  @type backend :: :quinn

  @typedoc "Requested connection transport."
  @type transport :: :auto | :raw_quic | :webtransport | :websocket

  @typedoc ~S|MOQ protocol version string, e.g. `"moq-lite-03"` or `"moq-transport-14"`.|
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

  @typedoc "Connection result delivered to the caller process."
  @type connect_message :: {:moqx_connected, session()} | {:error, String.t()}

  @typedoc "Subscription messages delivered to the caller process."
  @type subscribe_message ::
          {:moqx_subscribed, String.t(), String.t()}
          | {:moqx_frame, non_neg_integer(), binary()}
          | :moqx_track_ended
          | {:moqx_error, String.t()}

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
          | {:backend, backend()}
          | {:transport, transport()}
          | {:version, version() | [version()]}
          | {:tls, [tls_opt()]}

  @doc """
  Connects to a relay with an explicit role.

  Prefer `connect_publisher/2` and `connect_subscriber/2` unless you need to
  select the role dynamically.

  Supported options:

  - `:role` - required, `:publisher` or `:subscriber`
  - `:backend` - optional compiled backend, currently only `:quinn`
  - `:transport` - optional `:auto`, `:raw_quic`, `:webtransport`, or `:websocket`
  - `:version` - optional version string or list of version strings
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

    backend = opts |> Keyword.get(:backend) |> normalize_connect_backend()
    transport = opts |> Keyword.get(:transport, :auto) |> normalize_connect_transport!()
    versions = opts |> Keyword.get(:version, []) |> normalize_connect_versions!()
    {tls_verify, tls_cacertfile} = opts |> Keyword.get(:tls, []) |> normalize_connect_tls!()

    MOQX.Native.connect(url, role, backend, transport, versions, tls_verify, tls_cacertfile)
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
  Returns the compiled native backends available to `connect/2`.
  """
  @spec supported_backends() :: [backend()]
  def supported_backends do
    MOQX.Native.supported_backends()
    |> Enum.map(&normalize_session_backend!/1)
  end

  @doc """
  Returns the compiled native transports available to `connect/2`.
  """
  @spec supported_transports() :: [transport()]
  def supported_transports do
    MOQX.Native.supported_transports()
    |> Enum.map(&normalize_session_transport!/1)
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

  defp normalize_connect_backend(nil), do: nil
  defp normalize_connect_backend(:quinn), do: "quinn"

  defp normalize_connect_backend(backend) do
    raise ArgumentError,
          "expected :backend to be :quinn, got: #{inspect(backend)}"
  end

  defp normalize_connect_transport!(:auto), do: "auto"
  defp normalize_connect_transport!(:raw_quic), do: "raw_quic"
  defp normalize_connect_transport!(:webtransport), do: "webtransport"
  defp normalize_connect_transport!(:websocket), do: "websocket"

  defp normalize_connect_transport!(transport) do
    raise ArgumentError,
          "expected :transport to be :auto, :raw_quic, :webtransport, or :websocket, got: #{inspect(transport)}"
  end

  defp normalize_connect_versions!([]), do: []
  defp normalize_connect_versions!(version) when is_binary(version), do: [version]

  defp normalize_connect_versions!(versions) when is_list(versions) do
    Enum.map(versions, fn
      version when is_binary(version) ->
        version

      other ->
        raise ArgumentError, "expected :version entries to be strings, got: #{inspect(other)}"
    end)
  end

  defp normalize_connect_versions!(other) do
    raise ArgumentError,
          "expected :version to be a string or list of strings, got: #{inspect(other)}"
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

  defp normalize_session_backend!("quinn"), do: :quinn

  defp normalize_session_transport!("auto"), do: :auto
  defp normalize_session_transport!("raw_quic"), do: :raw_quic
  defp normalize_session_transport!("webtransport"), do: :webtransport
  defp normalize_session_transport!("websocket"), do: :websocket

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

  Subscribers receive `:moqx_track_ended` after the track is fully consumed.
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
  - `:moqx_track_ended` when the track finishes cleanly
  - `{:moqx_error, reason}` for asynchronous runtime failures

  Misuse errors, such as calling this with a publisher session, are returned as
  `{:error, reason}` immediately.
  """
  @spec subscribe(session(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def subscribe(session, broadcast_path, track_name)
      when is_binary(broadcast_path) and is_binary(track_name) do
    MOQX.Native.subscribe(session, broadcast_path, track_name)
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
