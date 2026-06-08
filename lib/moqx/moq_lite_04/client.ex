defmodule MOQX.MOQLite04.Client do
  @moduledoc """
  URI-first MOQ Lite draft-04 client connection value.

  This module establishes the transport connection and starts the pure
  `MOQX.MOQLite04.Session`. The public runner API keeps `command/2` and
  `recv/2` available for lower-level protocol use, while convenience operations
  open the required transport streams and delegate message encoding through
  `command/2`.
  """

  alias MOQX.MOQLite04
  alias MOQX.MOQLite04.Error, as: ProtocolError
  alias MOQX.MOQLite04.Session
  alias MOQX.Transport
  alias MOQX.Transport.{Capabilities, Connection, Context, Stream}

  @alpn "moq-lite-04"

  @enforce_keys [:uri, :context, :connection, :session]
  defstruct [:uri, :context, :connection, :session]

  defmodule Error do
    @moduledoc """
    Structured client runner error.
    """

    @enforce_keys [:reason]
    defstruct [:reason, :action, details: %{}]

    @type reason :: :transport_action_failed | :transport_receive_failed

    @type t :: %__MODULE__{
            reason: reason(),
            action: term() | nil,
            details: map()
          }

    @doc false
    @spec new(reason(), keyword()) :: t()
    def new(reason, opts \\ []) do
      %__MODULE__{
        reason: reason,
        action: Keyword.get(opts, :action),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  @type t :: %__MODULE__{
          uri: URI.t(),
          context: Context.t(),
          connection: Connection.t(),
          session: Session.t()
        }

  @type operation_result ::
          {:ok, t(), Stream.t(), [term()]} | {:error, t(), term(), [term()]}

  @type accept_result :: {:ok, t(), Stream.t()} | {:error, t(), term()}

  @doc """
  Connects to a native QUIC MOQ Lite draft-04 endpoint.
  """
  @spec connect(String.t() | URI.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(uri, opts \\ []) when is_list(opts) do
    with :ok <- reject_mode(opts),
         {:ok, parsed_uri} <- parse_uri(uri),
         {:ok, {transport, transport_opts}} <- fetch_transport(opts),
         {:ok, context} <- Transport.new(transport, transport_opts),
         timeout <- Keyword.get(opts, :timeout, 5_000),
         {:ok, connection, context} <-
           Transport.connect(context, parsed_uri.host, parsed_uri.port, [alpn: @alpn], timeout),
         {:ok, connection, context} <- Transport.handshake(context, connection, timeout),
         :ok <- verify_alpn(context, connection) do
      {:ok,
       %__MODULE__{
         uri: parsed_uri,
         context: context,
         connection: connection,
         session: Session.new(alpn: @alpn)
       }}
    else
      {:error, reason, _context} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Applies one local protocol command and its resulting transport actions.

  This is the low-level local application intent boundary. Higher-level
  subscribe, publish, and fetch APIs build on top of it.
  """
  @spec command(t(), term()) :: {:ok, t(), [term()]} | {:error, t(), term(), [term()]}
  def command(%__MODULE__{} = client, command) do
    case Session.handle_command(client.session, command) do
      {:ok, session, events, actions} ->
        client
        |> put_session(session)
        |> apply_actions(actions, events, nil)

      {:error, session, reason, events, actions} ->
        client
        |> put_session(session)
        |> apply_actions(actions, events, reason)
    end
  end

  @doc """
  Receives and handles one normalized transport event from the caller mailbox.

  Unknown mailbox messages are ignored and return `{:ok, client, []}`. A timeout
  returns `{:timeout, client}`.
  """
  @spec recv(t(), timeout()) ::
          {:ok, t(), [term()]} | {:error, t(), term(), [term()]} | {:timeout, t()}
  def recv(%__MODULE__{} = client, timeout \\ :infinity) do
    case Transport.receive_event(client.context, timeout) do
      {:ok, event, context} ->
        client
        |> put_context(context)
        |> handle_transport_event(event)

      {:unknown, _message, context} ->
        {:ok, put_context(client, context), []}

      {:timeout, context} ->
        {:timeout, put_context(client, context)}

      {:error, reason, context} ->
        error =
          Error.new(:transport_receive_failed,
            details: %{transport_reason: reason}
          )

        {:error, put_context(client, context), error, []}
    end
  end

  @doc """
  Accepts a peer-opened stream and starts active transport delivery.
  """
  @spec accept_stream(t(), timeout()) :: accept_result()
  def accept_stream(%__MODULE__{} = client, timeout \\ :infinity) do
    with {:ok, stream, context} <-
           Transport.accept_stream(client.context, client.connection, [], timeout),
         {:ok, context} <- Transport.set_active(context, stream, true) do
      {:ok, put_context(client, context), stream}
    else
      {:error, reason, context} ->
        error =
          Error.new(:transport_action_failed,
            action: :accept_stream,
            details: %{transport_reason: reason}
          )

        {:error, put_context(client, context), error}
    end
  end

  @doc """
  Opens an Announce transaction stream and sends `ANNOUNCE_INTEREST`.
  """
  @spec announce_interest(t(), MOQLite04.AnnounceInterest.t()) :: operation_result()
  def announce_interest(%__MODULE__{} = client, %MOQLite04.AnnounceInterest{} = message) do
    open_transaction(client, :announce, message)
  end

  @doc """
  Opens a Subscribe transaction stream and sends `SUBSCRIBE`.
  """
  @spec subscribe(t(), MOQLite04.Subscribe.t()) :: operation_result()
  def subscribe(%__MODULE__{} = client, %MOQLite04.Subscribe{} = message) do
    open_transaction(client, :subscribe, message)
  end

  @doc """
  Sends `SUBSCRIBE_UPDATE` on an existing Subscribe transaction stream.
  """
  @spec subscribe_update(t(), Stream.t(), MOQLite04.SubscribeUpdate.t()) :: operation_result()
  def subscribe_update(
        %__MODULE__{} = client,
        %Stream{} = stream,
        %MOQLite04.SubscribeUpdate{} = message
      ) do
    send_on_transaction(client, stream, :subscribe, message)
  end

  @doc """
  Opens a Fetch transaction stream and sends `FETCH`.
  """
  @spec fetch(t(), MOQLite04.Fetch.t()) :: operation_result()
  def fetch(%__MODULE__{} = client, %MOQLite04.Fetch{} = message) do
    open_transaction(client, :fetch, message)
  end

  @doc """
  Opens a Probe transaction stream and sends `PROBE`.
  """
  @spec probe(t(), MOQLite04.Probe.t()) :: operation_result()
  def probe(%__MODULE__{} = client, %MOQLite04.Probe{} = message) do
    open_transaction(client, :probe, message)
  end

  @doc """
  Sends `PROBE` on an existing Probe transaction stream.
  """
  @spec probe(t(), Stream.t(), MOQLite04.Probe.t()) :: operation_result()
  def probe(%__MODULE__{} = client, %Stream{} = stream, %MOQLite04.Probe{} = message) do
    send_on_transaction(client, stream, :probe, message)
  end

  @doc """
  Opens a Goaway transaction stream and sends `GOAWAY`.
  """
  @spec goaway(t(), MOQLite04.Goaway.t()) :: operation_result()
  def goaway(%__MODULE__{} = client, %MOQLite04.Goaway{} = message) do
    open_transaction(client, :goaway, message)
  end

  @doc """
  Sends `ANNOUNCE` on an existing Announce transaction stream.
  """
  @spec announce(t(), Stream.t(), MOQLite04.Announce.t()) :: operation_result()
  def announce(%__MODULE__{} = client, %Stream{} = stream, %MOQLite04.Announce{} = message) do
    send_on_transaction(client, stream, :announce, message)
  end

  @doc """
  Sends `SUBSCRIBE_OK` on an existing Subscribe transaction stream.
  """
  @spec subscribe_ok(t(), Stream.t(), MOQLite04.SubscribeOk.t()) :: operation_result()
  def subscribe_ok(%__MODULE__{} = client, %Stream{} = stream, %MOQLite04.SubscribeOk{} = message) do
    send_on_transaction(client, stream, :subscribe, message)
  end

  @doc """
  Sends `SUBSCRIBE_DROP` on an existing Subscribe transaction stream.
  """
  @spec subscribe_drop(t(), Stream.t(), MOQLite04.SubscribeDrop.t()) :: operation_result()
  def subscribe_drop(
        %__MODULE__{} = client,
        %Stream{} = stream,
        %MOQLite04.SubscribeDrop{} = message
      ) do
    send_on_transaction(client, stream, :subscribe, message)
  end

  @doc """
  Opens a publisher Group stream and sends `GROUP` followed by `FRAME` messages.
  """
  @spec publish_group(t(), MOQLite04.Group.t(), [MOQLite04.Frame.t()]) :: operation_result()
  def publish_group(%__MODULE__{} = client, %MOQLite04.Group{} = group, frames)
      when is_list(frames) do
    open_group_stream(client, [group | frames])
  end

  defp reject_mode(opts) do
    if Keyword.has_key?(opts, :mode) do
      {:error, {:unsupported_option, :mode}}
    else
      :ok
    end
  end

  defp parse_uri(%URI{} = uri), do: validate_uri(uri)
  defp parse_uri(uri) when is_binary(uri), do: uri |> URI.parse() |> validate_uri()
  defp parse_uri(uri), do: {:error, {:invalid_uri, {:unsupported_input, uri}}}

  defp validate_uri(%URI{scheme: nil}), do: {:error, {:invalid_uri, :missing_scheme}}

  defp validate_uri(%URI{scheme: scheme}) when scheme != "moq-lite",
    do: {:error, {:invalid_uri, {:unsupported_scheme, scheme}}}

  defp validate_uri(%URI{userinfo: userinfo}) when userinfo not in [nil, ""],
    do: {:error, {:invalid_uri, :userinfo_not_supported}}

  defp validate_uri(%URI{host: host}) when host in [nil, ""],
    do: {:error, {:invalid_uri, :missing_host}}

  defp validate_uri(%URI{port: nil}), do: {:error, {:invalid_uri, :missing_port}}

  defp validate_uri(%URI{fragment: fragment}) when fragment not in [nil, ""],
    do: {:error, {:invalid_uri, :fragment_not_supported}}

  defp validate_uri(%URI{} = uri), do: {:ok, uri}

  defp fetch_transport(opts) do
    case Keyword.fetch(opts, :transport) do
      {:ok, {transport, transport_opts}}
      when is_atom(transport) and (is_list(transport_opts) or is_map(transport_opts)) ->
        {:ok, {transport, transport_opts}}

      {:ok, invalid} ->
        {:error, {:invalid_transport, invalid}}

      :error ->
        {:error, :missing_transport}
    end
  end

  defp verify_alpn(context, connection) do
    case Transport.capabilities(context, connection) do
      %Capabilities{alpn: @alpn} ->
        :ok

      %Capabilities{alpn: actual} ->
        {:error,
         ProtocolError.new(:unknown_alpn,
           details: %{expected_alpn: @alpn, actual_alpn: actual}
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_context(%__MODULE__{} = client, context), do: %{client | context: context}

  defp put_session(%__MODULE__{} = client, session), do: %{client | session: session}

  defp open_transaction(%__MODULE__{} = client, stream_type, message) do
    with {:ok, stream, context} <-
           Transport.open_stream(client.context, client.connection, direction: :bidirectional),
         {:ok, context} <- Transport.set_active(context, stream, true) do
      client
      |> put_context(context)
      |> send_on_transaction(stream, stream_type, message)
    else
      {:error, reason, context} ->
        error =
          Error.new(:transport_action_failed,
            action: {:open_transaction, stream_type},
            details: %{transport_reason: reason}
          )

        {:error, put_context(client, context), error, []}
    end
  end

  defp open_group_stream(%__MODULE__{} = client, messages) do
    case Transport.open_stream(client.context, client.connection, direction: :unidirectional) do
      {:ok, stream, context} ->
        client
        |> put_context(context)
        |> send_on_stream(stream, :group, messages)

      {:error, reason, context} ->
        error =
          Error.new(:transport_action_failed,
            action: {:open_stream, :group},
            details: %{transport_reason: reason}
          )

        {:error, put_context(client, context), error, []}
    end
  end

  defp send_on_transaction(%__MODULE__{} = client, %Stream{} = stream, stream_type, message) do
    send_on_stream(client, stream, stream_type, [message])
  end

  defp send_on_stream(%__MODULE__{} = client, %Stream{} = stream, stream_type, messages) do
    case command(client, {:send, stream, stream_type, messages}) do
      {:ok, client, events} -> {:ok, client, stream, events}
      {:error, client, reason, events} -> {:error, client, reason, events}
    end
  end

  defp handle_transport_event(%__MODULE__{} = client, event) do
    case Session.handle_transport(client.session, event) do
      :unknown ->
        {:ok, client, []}

      {:ok, session, events, actions} ->
        client
        |> put_session(session)
        |> apply_actions(actions, events, nil)

      {:error, session, reason, events, actions} ->
        client
        |> put_session(session)
        |> apply_actions(actions, events, reason)
    end
  end

  defp apply_actions(client, actions, events, session_error) do
    case Enum.reduce_while(actions, {:ok, client}, &apply_action/2) do
      {:ok, client} when is_nil(session_error) ->
        {:ok, client, events}

      {:ok, client} ->
        {:error, client, session_error, events}

      {:error, client, action, reason} ->
        error =
          Error.new(:transport_action_failed,
            action: action,
            details: %{transport_reason: reason}
          )

        {:error, client, error, events}
    end
  end

  defp apply_action({:send_stream, stream, bytes, opts} = action, {:ok, client}) do
    case Transport.send_stream(client.context, stream, bytes, opts) do
      {:ok, _send, context} -> {:cont, {:ok, %{client | context: context}}}
      {:error, reason, context} -> {:halt, {:error, %{client | context: context}, action, reason}}
    end
  end

  defp apply_action({:finish_sending, stream} = action, {:ok, client}) do
    case Transport.finish_sending(client.context, stream) do
      {:ok, context} -> {:cont, {:ok, %{client | context: context}}}
      {:error, reason, context} -> {:halt, {:error, %{client | context: context}, action, reason}}
    end
  end

  defp apply_action({:abort_sending, stream, error_code} = action, {:ok, client}) do
    case Transport.abort_sending(client.context, stream, error_code) do
      {:ok, context} -> {:cont, {:ok, %{client | context: context}}}
      {:error, reason, context} -> {:halt, {:error, %{client | context: context}, action, reason}}
    end
  end

  defp apply_action({:abort_receiving, stream, error_code} = action, {:ok, client}) do
    case Transport.abort_receiving(client.context, stream, error_code) do
      {:ok, context} -> {:cont, {:ok, %{client | context: context}}}
      {:error, reason, context} -> {:halt, {:error, %{client | context: context}, action, reason}}
    end
  end

  defp apply_action({:close_connection, connection, error_code} = action, {:ok, client}) do
    case Transport.close_connection(client.context, connection, error_code) do
      {:ok, context} -> {:cont, {:ok, %{client | context: context}}}
      {:error, reason, context} -> {:halt, {:error, %{client | context: context}, action, reason}}
    end
  end

  defp apply_action(action, {:ok, client}) do
    {:halt, {:error, client, action, {:unsupported_transport_action, action}}}
  end
end
