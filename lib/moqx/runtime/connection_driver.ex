defmodule MOQX.Runtime.ConnectionDriver do
  @moduledoc """
  Process-owned bridge between one protocol implementation and `MOQX.Transport`.

  The driver owns the transport context, stream handles and receive loop. A
  protocol implementation remains a pure reducer and requests IO through
  transition actions keyed by logical stream names.
  """

  alias MOQX.Operation
  alias MOQX.Protocol.Transition
  alias MOQX.Transport

  defstruct [
    :event_recipient,
    :event_recipient_monitor,
    :client,
    :protocol,
    :protocol_state,
    :context,
    :connection,
    streams: %{},
    timers: %{}
  ]

  @type state :: %__MODULE__{}

  @spec start(URI.t(), module(), keyword(), pid()) :: {:ok, MOQX.Client.t()} | {:error, term()}
  def start(endpoint, protocol, options, event_recipient) do
    timeout = Keyword.get(options, :timeout, 5_000)
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        initialize(caller, ref, event_recipient, endpoint, protocol, options)
      end)

    receive do
      {^ref, {:ok, %MOQX.Client{} = client}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, client}

      {^ref, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        {:error, reason}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:connection_driver_failed, reason}}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end

  @spec subscribe(MOQX.Client.t(), MOQX.TrackRef.t(), keyword()) ::
          {:ok, MOQX.Subscription.t()} | {:error, term()}
  def subscribe(%MOQX.Client{pid: pid}, track, options) do
    call(pid, {:operation, %Operation.Subscribe{track: track, options: options}}, 5_000)
  end

  @spec unsubscribe(MOQX.Client.t(), MOQX.Subscription.t()) :: :ok | {:error, term()}
  def unsubscribe(%MOQX.Client{pid: pid}, subscription) do
    call(pid, {:operation, %Operation.Unsubscribe{subscription: subscription}}, 5_000)
  end

  @spec publish(MOQX.Client.t(), [binary()], keyword()) ::
          {:ok, MOQX.Publication.t()} | {:error, term()}
  def publish(%MOQX.Client{pid: pid}, namespace, options) do
    call(pid, {:operation, %Operation.Publish{namespace: namespace, options: options}}, 5_000)
  end

  @spec add_track(MOQX.Client.t(), MOQX.Publication.t(), binary(), keyword()) ::
          {:ok, MOQX.PublishedTrack.t()} | {:error, term()}
  def add_track(%MOQX.Client{pid: pid}, publication, track, options) do
    operation = %Operation.AddTrack{publication: publication, track: track, options: options}
    call(pid, {:operation, operation}, 5_000)
  end

  @spec publish_object(MOQX.Client.t(), MOQX.PublishedTrack.t(), MOQX.Object.t()) ::
          :ok | {:error, term()}
  def publish_object(%MOQX.Client{pid: pid}, track, object) do
    call(pid, {:operation, %Operation.PublishObject{track: track, object: object}}, 5_000)
  end

  @spec finish_publication(MOQX.Client.t(), MOQX.Publication.t(), keyword()) ::
          :ok | {:error, term()}
  def finish_publication(%MOQX.Client{pid: pid}, publication, options) do
    operation = %Operation.FinishPublication{publication: publication, options: options}
    call(pid, {:operation, operation}, 5_000)
  end

  @spec close(MOQX.Client.t(), term()) :: :ok | {:error, term()}
  def close(%MOQX.Client{pid: pid}, reason) do
    case call(pid, {:operation, %Operation.Close{reason: reason}}, 5_000) do
      {:error, {:connection_closed, :noproc}} -> :ok
      result -> result
    end
  end

  defp call(pid, request, timeout) do
    ref = make_ref()
    monitor = Process.monitor(pid)
    send(pid, {:moqx_call, self(), ref, request})

    receive do
      {^ref, reply} ->
        Process.demonitor(monitor, [:flush])
        reply

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:connection_closed, reason}}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end

  defp initialize(caller, ref, event_recipient, endpoint, protocol, options) do
    with {:ok, transport_spec} <- protocol.transport_spec(endpoint, options),
         {backend, backend_options} <- transport_selection(options),
         {:ok, context} <- Transport.new(backend, backend_options),
         {:ok, host, port} <- endpoint_address(endpoint),
         connect_options <-
           Keyword.merge(
             transport_spec.connect_options,
             Keyword.get(options, :connect_options, [])
           ),
         {:ok, connection, context} <-
           Transport.connect(
             context,
             host,
             port,
             connect_options,
             Keyword.get(options, :timeout, 5_000)
           ),
         {:ok, protocol_state} <- protocol.init(endpoint, options) do
      client = %MOQX.Client{pid: self(), protocol: protocol.id()}

      state = %__MODULE__{
        event_recipient: event_recipient,
        event_recipient_monitor: Process.monitor(event_recipient),
        client: client,
        protocol: protocol,
        protocol_state: protocol_state,
        context: context,
        connection: connection
      }

      case transition(
             state,
             protocol.handle_transport(
               protocol_state,
               {:connection_event, connection, :ready, %{}}
             )
           ) do
        {:ok, state} -> loop(state, {caller, ref})
        {:error, reason, _state} -> send(caller, {ref, {:error, reason}})
      end
    else
      {:error, reason, _context} -> send(caller, {ref, {:error, reason}})
      {:error, reason} -> send(caller, {ref, {:error, reason}})
    end
  end

  defp loop(state, waiter) do
    {state, waiter} =
      receive do
        message -> handle_message(state, waiter, message)
      after
        5 -> {accept_peer_stream(state), waiter}
      end

    loop(state, waiter)
  end

  defp handle_message(state, waiter, {:moqx_call, caller, ref, {:operation, operation}}) do
    case state.protocol.handle_operation(state.protocol_state, operation) do
      {:ok, %Transition{} = protocol_transition} ->
        reply_operation(state, waiter, caller, ref, protocol_transition)

      {:error, reason, %Transition{} = protocol_transition} ->
        state = %{state | protocol_state: protocol_transition.state}
        send(caller, {ref, {:error, reason}})
        {state, waiter}
    end
  end

  defp handle_message(
         %{event_recipient_monitor: monitor} = state,
         waiter,
         {:DOWN, monitor, :process, _pid, _reason}
       ) do
    _result = Transport.close_connection(state.context, state.connection, 0)
    exit(:normal)
    {state, waiter}
  end

  defp handle_message(state, waiter, {:moqx_runtime_timeout, key, token}) do
    case state.timers[key] do
      {_timer, ^token} ->
        state = %{state | timers: Map.delete(state.timers, key)}
        handle_protocol_runtime_event(state, waiter, {:runtime_timeout, key})

      _other ->
        {state, waiter}
    end
  end

  defp handle_message(state, waiter, message) do
    case Transport.normalize_event(state.context, state.connection, message) do
      {:ok, event, context} -> handle_transport_event(%{state | context: context}, waiter, event)
      {:unknown, _message, _context} -> {state, waiter}
      {:error, {:unknown_transport_handle, _handle}, _context} -> {state, waiter}
    end
  end

  defp reply_operation(state, waiter, caller, ref, protocol_transition) do
    stop? = :connection_ended in protocol_transition.events
    {reply, public_events} = operation_reply(protocol_transition.events)
    protocol_transition = %{protocol_transition | events: public_events}

    case transition(state, {:ok, protocol_transition}) do
      {:ok, state} ->
        send(caller, {ref, reply})

        if stop? do
          exit(:normal)
        else
          {state, waiter}
        end

      {:error, reason, state} ->
        send(caller, {ref, {:error, reason}})
        {state, waiter}
    end
  end

  defp handle_transport_event(state, waiter, event) do
    state = activate_peer_stream(state, event)
    result = state.protocol.handle_transport(state.protocol_state, event)

    case transition(state, result) do
      {:ok, state} -> maybe_stop_after_transport(state, waiter, event)
      {:error, reason, state} -> fail_waiter_or_owner(state, waiter, reason)
    end
  end

  defp handle_protocol_runtime_event(state, waiter, event) do
    case transition(state, state.protocol.handle_transport(state.protocol_state, event)) do
      {:ok, state} -> {state, waiter}
      {:error, reason, state} -> fail_waiter_or_owner(state, waiter, reason)
    end
  end

  defp maybe_stop_after_transport(
         _state,
         _waiter,
         {:connection_event, _conn, :closed, _metadata}
       ) do
    exit(:normal)
  end

  defp maybe_stop_after_transport(state, waiter, _event) do
    {state, maybe_ready(state, waiter)}
  end

  defp activate_peer_stream(state, {:stream_event, stream, :new_stream, _metadata}) do
    case Transport.set_active(state.context, stream, true) do
      {:ok, context} -> %{state | context: context}
      {:error, _reason, context} -> %{state | context: context}
    end
  end

  defp activate_peer_stream(state, _event), do: state

  defp transition(state, {:ok, %Transition{} = protocol_transition}) do
    state = %{state | protocol_state: protocol_transition.state}

    with {:ok, state} <- apply_actions(state, protocol_transition.actions) do
      deliver_events(state, protocol_transition.events)
      {:ok, state}
    end
  end

  defp transition(state, {:error, reason, %Transition{} = protocol_transition}) do
    state = %{state | protocol_state: protocol_transition.state}

    case apply_actions(state, protocol_transition.actions) do
      {:ok, state} -> {:error, reason, state}
      {:error, action_reason, state} -> {:error, {:transport_action_failed, action_reason}, state}
    end
  end

  defp apply_actions(state, actions) do
    Enum.reduce_while(actions, {:ok, state}, fn action, {:ok, state} ->
      case apply_action(state, action) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason, state} -> {:halt, {:error, reason, state}}
      end
    end)
  end

  defp apply_action(state, {:open_stream, key, options, initial_data}) do
    apply_action(state, {:open_stream, key, options, initial_data, []})
  end

  defp apply_action(state, {:open_stream, key, options, initial_data, send_options}) do
    active = Keyword.get(options, :active, false)

    with {:ok, stream, context} <- Transport.open_stream(state.context, state.connection, options),
         {:ok, context} <- maybe_set_active(context, stream, active),
         {:ok, _send, context} <-
           Transport.send_stream(context, stream, transport_data(initial_data), send_options) do
      streams =
        if Keyword.get(send_options, :finish, false) do
          state.streams
        else
          Map.put(state.streams, key, stream)
        end

      {:ok, %{state | context: context, streams: streams}}
    else
      {:error, reason, context} -> {:error, reason, %{state | context: context}}
    end
  end

  defp apply_action(state, {:send_stream, key, data, options}) do
    with {:ok, stream} <- Map.fetch(state.streams, key),
         {:ok, _send, context} <-
           Transport.send_stream(state.context, stream, transport_data(data), options) do
      {:ok, %{state | context: context}}
    else
      :error -> {:error, {:unknown_stream_key, key}, state}
      {:error, reason, context} -> {:error, reason, %{state | context: context}}
    end
  end

  defp apply_action(state, {:close_connection, error_code}) do
    case Transport.close_connection(state.context, state.connection, error_code) do
      {:ok, context} -> {:ok, %{state | context: context}}
      {:error, reason, context} -> {:error, reason, %{state | context: context}}
    end
  end

  defp apply_action(state, {:start_timer, key, timeout})
       when is_integer(timeout) and timeout >= 0 do
    state = cancel_timer(state, key)
    token = make_ref()
    timer = Process.send_after(self(), {:moqx_runtime_timeout, key, token}, timeout)
    {:ok, %{state | timers: Map.put(state.timers, key, {timer, token})}}
  end

  defp apply_action(state, {:cancel_timer, key}) do
    {:ok, cancel_timer(state, key)}
  end

  defp cancel_timer(state, key) do
    case Map.pop(state.timers, key) do
      {nil, _timers} ->
        state

      {{timer, _token}, timers} ->
        _result = Process.cancel_timer(timer)
        %{state | timers: timers}
    end
  end

  defp maybe_set_active(context, _stream, false), do: {:ok, context}

  defp maybe_set_active(context, stream, active),
    do: Transport.set_active(context, stream, active)

  defp transport_data(%MOQX.Sensitive{} = sensitive), do: MOQX.Sensitive.reveal(sensitive)
  defp transport_data(data), do: data

  defp accept_peer_stream(state) do
    case Transport.accept_stream(state.context, state.connection, [], 10) do
      {:ok, stream, context} ->
        case Transport.set_active(context, stream, true) do
          {:ok, context} -> %{state | context: context}
          {:error, _reason, context} -> %{state | context: context}
        end

      {:error, :timeout, context} ->
        %{state | context: context}

      {:error, _reason, context} ->
        %{state | context: context}
    end
  end

  defp deliver_events(state, events) do
    Enum.each(events, fn
      :ready -> :ok
      {:subscription_started, _subscription} -> :ok
      event -> send(state.event_recipient, {:moqx, state.client, event})
    end)
  end

  defp operation_reply(events) do
    case Enum.find(events, &operation_reply_event?/1) do
      {:subscription_started, subscription} ->
        {{:ok, subscription}, Enum.reject(events, &match?({:subscription_started, _}, &1))}

      {:subscription_ended, _subscription} ->
        {:ok, Enum.reject(events, &match?({:subscription_ended, _}, &1))}

      {:publication_started, publication} ->
        {{:ok, publication}, Enum.reject(events, &match?({:publication_started, _}, &1))}

      {:track_added, track} ->
        {{:ok, track}, Enum.reject(events, &match?({:track_added, _}, &1))}

      {:object_published, _track} ->
        {:ok, Enum.reject(events, &match?({:object_published, _}, &1))}

      {:publication_finished, _publication} ->
        {:ok, Enum.reject(events, &match?({:publication_finished, _}, &1))}

      :connection_ended ->
        {:ok, Enum.reject(events, &(&1 == :connection_ended))}

      nil ->
        {:ok, events}
    end
  end

  defp operation_reply_event?({:subscription_started, _subscription}), do: true
  defp operation_reply_event?({:subscription_ended, _subscription}), do: true
  defp operation_reply_event?({:publication_started, _publication}), do: true
  defp operation_reply_event?({:track_added, _track}), do: true
  defp operation_reply_event?({:object_published, _track}), do: true
  defp operation_reply_event?({:publication_finished, _publication}), do: true
  defp operation_reply_event?(:connection_ended), do: true
  defp operation_reply_event?(_event), do: false

  defp maybe_ready(_state, nil), do: nil

  defp maybe_ready(%{protocol_state: %{phase: :ready}, client: client}, {caller, ref}) do
    send(caller, {ref, {:ok, client}})
    nil
  end

  defp maybe_ready(_state, waiter), do: waiter

  defp fail_waiter_or_owner(_state, {caller, ref}, reason) do
    send(caller, {ref, {:error, reason}})
    exit({:protocol_error, reason})
  end

  defp fail_waiter_or_owner(state, nil, reason) do
    send(state.event_recipient, {
      :moqx,
      state.client,
      %MOQX.Event.ProtocolFailed{reason: reason}
    })

    exit({:protocol_error, reason})
  end

  defp transport_selection(options) do
    case Keyword.get(options, :transport, MOQX.Transport.Quicer) do
      {backend, backend_options} -> {backend, backend_options}
      backend -> {backend, []}
    end
  end

  defp endpoint_address(%URI{host: host} = endpoint) when is_binary(host) do
    {:ok, host, endpoint.port || 443}
  end

  defp endpoint_address(_endpoint), do: {:error, :invalid_endpoint}
end
