defmodule MOQX.MOQLite04.Session do
  @moduledoc """
  Pure MOQ Lite draft-04 protocol session reducer.

  The session owns protocol state above one negotiated transport connection. It
  consumes normalized `MOQX.Transport` events and local application commands,
  then returns updated state, typed protocol events, and transport actions as
  data for a runner to apply.
  """

  alias MOQX.MOQLite04
  alias MOQX.MOQLite04.Error
  alias MOQX.MOQLite04.StreamCodec
  alias MOQX.Transport.Conn
  alias MOQX.Transport.Conn.Stream

  @alpn "moq-lite-04"

  @type t :: %__MODULE__{
          alpn: String.t(),
          streams: map(),
          next_stream_ref: non_neg_integer(),
          local_subscriptions: map(),
          peer_subscriptions: map(),
          draining?: boolean()
        }

  defstruct alpn: @alpn,
            streams: %{},
            next_stream_ref: 0,
            local_subscriptions: %{},
            peer_subscriptions: %{},
            draining?: false

  defmodule StreamState do
    @moduledoc false

    @enforce_keys [:ref, :stream, :recv_codec]
    defstruct [
      :ref,
      :stream,
      :stream_type,
      :recv_codec,
      :send_codec,
      :subscribe_id,
      announce_statuses: %{},
      subscribe_response_started?: false
    ]
  end

  @doc """
  Starts an active MOQ Lite draft-04 protocol session.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      alpn: Keyword.get(opts, :alpn, @alpn)
    }
  end

  @doc """
  Handles one normalized transport event.
  """
  @spec handle_transport(t(), MOQX.Transport.event()) ::
          :unknown
          | {:ok, t(), [term()], [term()]}
          | {:error, t(), Error.t(), [term()], [term()]}
  def handle_transport(
        %__MODULE__{} = session,
        {:stream_data, %Stream{} = stream, bytes, _metadata}
      ) do
    stream_key = stream_key(stream)

    stream_state =
      Map.get(session.streams, stream_key, initial_recv_stream_state(session, stream))

    case StreamCodec.recv(stream_state.recv_codec, bytes) do
      {:ok, recv_codec, messages} ->
        stream_started? = is_nil(stream_state.stream_type) and not is_nil(recv_codec.stream_type)

        stream_state = %{
          stream_state
          | recv_codec: recv_codec,
            stream_type: recv_codec.stream_type
        }

        case apply_received_messages(session, stream_state, messages) do
          {:ok, session, stream_state} ->
            session = put_stream(session, stream_key, stream_state)
            events = stream_events(stream_state, messages, stream_started?)

            {:ok, session, events, []}

          {:error, error} ->
            {:error, session, error, [], abort_stream_actions(stream, error)}
        end

      {:error, :unknown_stream_type, _codec} ->
        error = Error.new(:unexpected_stream, details: %{stream_id: stream.info.stream_id})

        {:error, session, error, [], abort_stream_actions(stream, error)}

      {:error, reason, _codec} ->
        error =
          Error.new(:decode_error,
            details: %{stream_id: stream.info.stream_id, decode_reason: reason}
          )

        {:error, session, error, [], abort_stream_actions(stream, error)}
    end
  end

  def handle_transport(
        %__MODULE__{} = session,
        {:stream_event, %Stream{} = stream, :peer_finished_sending, _metadata}
      ) do
    case fetch_stream(session, stream) do
      {:ok, stream_state} ->
        {:ok, session, [{:stream_finished, stream_state.ref, stream}], []}

      :error ->
        :unknown
    end
  end

  def handle_transport(
        %__MODULE__{} = session,
        {:stream_event, %Stream{} = stream, event, %{error_code: error_code}}
      )
      when event in [:peer_aborted_sending, :peer_aborted_receiving] do
    case fetch_stream(session, stream) do
      {:ok, stream_state} ->
        error = Error.from_code(error_code)

        {:ok, session, [{:stream_aborted, stream_state.ref, stream, error}], []}

      :error ->
        :unknown
    end
  end

  def handle_transport(%__MODULE__{}, _event), do: :unknown

  @doc """
  Handles local application intent and returns transport actions as data.
  """
  @spec handle_command(t(), term()) ::
          {:ok, t(), [term()], [term()]}
          | {:error, t(), Error.t(), [term()], [term()]}
  def handle_command(%__MODULE__{} = session, {:finish_sending, %Stream{} = stream}) do
    {:ok, session, [], [{:finish_sending, stream}]}
  end

  def handle_command(%__MODULE__{} = session, {:abort_sending, %Stream{} = stream, reason}) do
    handle_abort_command(session, :abort_sending, stream, reason)
  end

  def handle_command(%__MODULE__{} = session, {:abort_receiving, %Stream{} = stream, reason}) do
    handle_abort_command(session, :abort_receiving, stream, reason)
  end

  def handle_command(
        %__MODULE__{} = session,
        {:close_connection, %Conn{} = connection, reason}
      ) do
    case Error.code(reason) do
      {:ok, code} ->
        {:ok, session, [], [{:close_connection, connection, code}]}

      {:error, error_reason} ->
        error = Error.new(:protocol_violation, details: %{error_reason: error_reason})

        {:error, session, error, [], []}
    end
  end

  def handle_command(%__MODULE__{} = session, {:send, stream, stream_type, messages}) do
    handle_command(session, {:send, stream, stream_type, messages, []})
  end

  def handle_command(
        %__MODULE__{} = session,
        {:send, %Stream{} = stream, stream_type, messages, opts}
      )
      when is_list(messages) do
    stream_key = stream_key(stream)

    if reject_new_stream?(session, stream_key) do
      error = Error.new(:closed, details: %{stream_id: stream.info.stream_id})

      {:error, session, error, [], []}
    else
      send_messages(session, stream_key, stream, stream_type, messages, opts)
    end
  end

  defp handle_abort_command(%__MODULE__{} = session, action, %Stream{} = stream, reason) do
    case Error.code(reason) do
      {:ok, code} ->
        {:ok, session, [], [{action, stream, code}]}

      {:error, error_reason} ->
        error = Error.new(:protocol_violation, details: %{error_reason: error_reason})

        {:error, session, error, [], []}
    end
  end

  defp send_messages(
         %__MODULE__{} = session,
         stream_key,
         %Stream{} = stream,
         stream_type,
         messages,
         opts
       ) do
    stream_state =
      Map.get(
        session.streams,
        stream_key,
        initial_send_stream_state(session, stream, stream_type)
      )

    send_codec =
      stream_state.send_codec ||
        StreamCodec.new(side: :responder, stream_type: stream_state.stream_type)

    stream_state = %{stream_state | send_codec: send_codec}

    with :ok <- validate_send_messages(session, stream_state, messages),
         {:ok, send_codec, bytes} <- StreamCodec.encode_next(send_codec, messages) do
      stream_state = %{stream_state | stream_type: stream_type, send_codec: send_codec}
      {session, stream_state} = apply_sent_messages(session, stream_state, messages)
      session = put_stream(session, stream_key, stream_state)

      {:ok, session, [], [{:send_stream, stream, bytes, opts}]}
    else
      {:error, %Error{} = error} ->
        {:error, session, error, [], []}

      {:error, reason, _codec} ->
        error =
          Error.new(:encode_error,
            details: %{stream_id: stream.info.stream_id, encode_reason: reason}
          )

        {:error, session, error, [], []}
    end
  end

  defp initial_recv_stream_state(%__MODULE__{} = session, %Stream{} = stream) do
    %StreamState{
      ref: session.next_stream_ref,
      stream: stream,
      recv_codec: StreamCodec.new(side: recv_side(stream))
    }
  end

  defp initial_send_stream_state(%__MODULE__{} = session, %Stream{} = stream, stream_type) do
    %StreamState{
      ref: session.next_stream_ref,
      stream: stream,
      stream_type: stream_type,
      recv_codec: StreamCodec.new(side: :responder, stream_type: stream_type),
      send_codec: StreamCodec.new(side: :opener, stream_type: stream_type)
    }
  end

  defp recv_side(%Stream{info: %{initiator: :peer}}), do: :opener
  defp recv_side(%Stream{info: %{initiator: :local}}), do: :responder

  defp put_stream(session, stream_key, %StreamState{ref: ref} = stream_state) do
    next_stream_ref = max(session.next_stream_ref, ref + 1)

    %{
      session
      | streams: Map.put(session.streams, stream_key, stream_state),
        next_stream_ref: next_stream_ref
    }
  end

  defp stream_key(%Stream{info: %{stream_id: stream_id}}), do: stream_id

  defp fetch_stream(%__MODULE__{} = session, %Stream{} = stream) do
    Map.fetch(session.streams, stream_key(stream))
  end

  defp reject_new_stream?(%__MODULE__{draining?: false}, _stream_key), do: false

  defp reject_new_stream?(%__MODULE__{streams: streams, draining?: true}, stream_key) do
    not Map.has_key?(streams, stream_key)
  end

  defp stream_events(%StreamState{}, [], false), do: []

  defp stream_events(%StreamState{} = stream_state, messages, stream_started?) do
    start_event =
      if stream_started? do
        [{:stream_started, stream_state.ref, stream_state.stream, stream_state.stream_type}]
      else
        []
      end

    start_event ++ Enum.map(messages, &message_event(stream_state, &1))
  end

  defp message_event(%StreamState{} = stream_state, %MOQLite04.Goaway{} = message) do
    {:goaway, stream_state.ref, stream_state.stream, message.new_session_uri}
  end

  defp message_event(%StreamState{} = stream_state, message) do
    {:message, stream_state.ref, stream_state.stream, message}
  end

  defp apply_sent_messages(%__MODULE__{} = session, %StreamState{} = stream_state, messages) do
    Enum.reduce(messages, {session, stream_state}, fn message, {session, stream_state} ->
      apply_sent_message(session, stream_state, message)
    end)
  end

  defp apply_sent_message(
         %__MODULE__{} = session,
         %StreamState{stream_type: :subscribe, send_codec: %{side: :opener}} = stream_state,
         %MOQLite04.Subscribe{} = message
       ) do
    subscription = %{state: :pending, stream_ref: stream_state.ref}

    session = put_in(session.local_subscriptions[message.subscribe_id], subscription)
    stream_state = %{stream_state | subscribe_id: message.subscribe_id}

    {session, stream_state}
  end

  defp apply_sent_message(
         %__MODULE__{} = session,
         %StreamState{stream_type: :subscribe, send_codec: %{side: :responder}} = stream_state,
         %MOQLite04.SubscribeOk{}
       ) do
    session = activate_peer_subscription(session, stream_state.subscribe_id)

    {session, %{stream_state | subscribe_response_started?: true}}
  end

  defp apply_sent_message(
         %__MODULE__{} = session,
         %StreamState{stream_type: :announce, send_codec: %{side: :responder}} = stream_state,
         %MOQLite04.Announce{} = message
       ) do
    {:ok, stream_state} = apply_announce_status(stream_state, message)

    {session, stream_state}
  end

  defp apply_sent_message(%__MODULE__{} = session, %StreamState{} = stream_state, _message),
    do: {session, stream_state}

  defp validate_send_messages(
         %__MODULE__{} = session,
         %StreamState{stream_type: :group, send_codec: %{side: :opener}},
         messages
       ) do
    case Enum.find(messages, &match?(%MOQLite04.Group{}, &1)) do
      nil ->
        :ok

      %MOQLite04.Group{} = message ->
        validate_peer_subscription(session, message.subscribe_id)
    end
  end

  defp validate_send_messages(
         %__MODULE__{},
         %StreamState{stream_type: :subscribe, send_codec: %{side: :responder}} = stream_state,
         messages
       ) do
    validate_subscribe_responses(stream_state.subscribe_response_started?, messages)
  end

  defp validate_send_messages(
         %__MODULE__{},
         %StreamState{stream_type: :announce, send_codec: %{side: :responder}} = stream_state,
         messages
       ) do
    validate_announce_messages(stream_state, messages)
  end

  defp validate_send_messages(%__MODULE__{}, %StreamState{}, _messages), do: :ok

  defp validate_subscribe_responses(_started?, []), do: :ok

  defp validate_subscribe_responses(false, [%MOQLite04.SubscribeDrop{} | _rest]) do
    {:error,
     Error.new(:protocol_violation,
       details: %{stream_type: :subscribe, message: :subscribe_drop}
     )}
  end

  defp validate_subscribe_responses(_started?, [%MOQLite04.SubscribeOk{} | rest]),
    do: validate_subscribe_responses(true, rest)

  defp validate_subscribe_responses(started?, [_message | rest]),
    do: validate_subscribe_responses(started?, rest)

  defp validate_announce_messages(%StreamState{} = stream_state, messages) do
    Enum.reduce_while(messages, {:ok, stream_state}, fn
      %MOQLite04.Announce{} = message, {:ok, stream_state} ->
        case apply_announce_status(stream_state, message) do
          {:ok, stream_state} -> {:cont, {:ok, stream_state}}
          {:error, error} -> {:halt, {:error, error}}
        end

      _message, {:ok, stream_state} ->
        {:cont, {:ok, stream_state}}
    end)
    |> case do
      {:ok, _stream_state} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp validate_peer_subscription(%__MODULE__{} = session, subscribe_id) do
    case Map.fetch(session.peer_subscriptions, subscribe_id) do
      {:ok, %{state: :active}} ->
        :ok

      _error ->
        {:error,
         Error.new(:not_found,
           details: %{stream_type: :group, subscribe_id: subscribe_id}
         )}
    end
  end

  defp apply_received_messages(%__MODULE__{} = session, %StreamState{} = stream_state, messages) do
    Enum.reduce_while(messages, {:ok, session, stream_state}, fn message,
                                                                 {:ok, session, stream_state} ->
      case apply_received_message(session, stream_state, message) do
        {:ok, session, stream_state} -> {:cont, {:ok, session, stream_state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp apply_received_message(
         %__MODULE__{} = _session,
         %StreamState{
           stream_type: :subscribe,
           recv_codec: %{side: :responder},
           subscribe_response_started?: false
         },
         %MOQLite04.SubscribeDrop{}
       ) do
    {:error,
     Error.new(:protocol_violation,
       details: %{stream_type: :subscribe, message: :subscribe_drop}
     )}
  end

  defp apply_received_message(
         %__MODULE__{} = session,
         %StreamState{stream_type: :subscribe, recv_codec: %{side: :responder}} = stream_state,
         %MOQLite04.SubscribeOk{}
       ) do
    session = activate_local_subscription(session, stream_state.subscribe_id)

    {:ok, session, %{stream_state | subscribe_response_started?: true}}
  end

  defp apply_received_message(
         %__MODULE__{} = session,
         %StreamState{stream_type: :subscribe, recv_codec: %{side: :opener}} = stream_state,
         %MOQLite04.Subscribe{} = message
       ) do
    subscription = %{state: :pending, stream_ref: stream_state.ref}

    session = put_in(session.peer_subscriptions[message.subscribe_id], subscription)
    stream_state = %{stream_state | subscribe_id: message.subscribe_id}

    {:ok, session, stream_state}
  end

  defp apply_received_message(
         %__MODULE__{} = session,
         %StreamState{stream_type: :announce, recv_codec: %{side: :responder}} = stream_state,
         %MOQLite04.Announce{} = message
       ) do
    case apply_announce_status(stream_state, message) do
      {:ok, stream_state} -> {:ok, session, stream_state}
      {:error, error} -> {:error, error}
    end
  end

  defp apply_received_message(
         %__MODULE__{} = session,
         %StreamState{stream_type: :group} = stream_state,
         %MOQLite04.Group{} = message
       ) do
    case Map.fetch(session.local_subscriptions, message.subscribe_id) do
      {:ok, %{state: :active}} ->
        {:ok, session, stream_state}

      _error ->
        {:error,
         Error.new(:not_found,
           details: %{stream_type: :group, subscribe_id: message.subscribe_id}
         )}
    end
  end

  defp apply_received_message(
         %__MODULE__{} = session,
         %StreamState{stream_type: :goaway} = stream_state,
         %MOQLite04.Goaway{}
       ) do
    {:ok, %{session | draining?: true}, stream_state}
  end

  defp apply_received_message(%__MODULE__{} = session, %StreamState{} = stream_state, _message),
    do: {:ok, session, stream_state}

  defp activate_local_subscription(%__MODULE__{} = session, nil), do: session

  defp activate_local_subscription(%__MODULE__{} = session, subscribe_id) do
    update_in(session.local_subscriptions[subscribe_id], fn
      nil -> %{state: :active}
      subscription -> %{subscription | state: :active}
    end)
  end

  defp activate_peer_subscription(%__MODULE__{} = session, nil), do: session

  defp activate_peer_subscription(%__MODULE__{} = session, subscribe_id) do
    update_in(session.peer_subscriptions[subscribe_id], fn
      nil -> %{state: :active}
      subscription -> %{subscription | state: :active}
    end)
  end

  defp apply_announce_status(%StreamState{} = stream_state, %MOQLite04.Announce{} = message) do
    previous_status = Map.get(stream_state.announce_statuses, message.broadcast_path_suffix)

    if previous_status == message.status do
      {:error,
       Error.new(:protocol_violation,
         details: %{
           stream_type: :announce,
           broadcast_path_suffix: message.broadcast_path_suffix,
           status: message.status
         }
       )}
    else
      stream_state =
        put_in(stream_state.announce_statuses[message.broadcast_path_suffix], message.status)

      {:ok, stream_state}
    end
  end

  defp abort_stream_actions(%Stream{} = stream, %Error{} = error) do
    []
    |> maybe_abort_receiving(stream, error)
    |> maybe_abort_sending(stream, error)
    |> Enum.reverse()
  end

  defp maybe_abort_receiving(actions, %Stream{info: %{receive_side?: true}} = stream, error),
    do: [{:abort_receiving, stream, error.code} | actions]

  defp maybe_abort_receiving(actions, %Stream{}, %Error{}), do: actions

  defp maybe_abort_sending(actions, %Stream{info: %{send_side?: true}} = stream, error),
    do: [{:abort_sending, stream, error.code} | actions]

  defp maybe_abort_sending(actions, %Stream{}, %Error{}), do: actions
end
