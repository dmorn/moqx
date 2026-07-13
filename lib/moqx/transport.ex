defmodule MOQX.Transport do
  @moduledoc """
  QUIC transport boundary for MOQT-family implementations.

  Protocol code should use this façade instead of backend modules directly.
  New code uses caller-owned `%MOQX.Transport.Context{}` values and opaque
  wrapper handles.
  """

  alias MOQX.Transport.{BackendRef, Conn, Context, Listener}
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.{Info, Send, Sender}

  @type listener :: term()
  @type connection :: term()
  @type stream :: term()
  @type event ::
          {:listener_event, listener() | connection(), atom(), term()}
          | {:connection_event, connection(), atom(), term()}
          | {:stream_event, stream(), atom(), term()}
          | {:stream_data, stream(), binary(), map()}
          | {:datagram, connection(), binary(), term()}

  @callback listen(port :: non_neg_integer() | String.t(), opts :: keyword() | map()) ::
              {:ok, listener()} | {:error, term()}

  @callback local_address(listener() | connection()) ::
              {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}

  @callback close_listener(listener(), timeout()) :: :ok | {:error, term()}

  @callback accept(listener(), opts :: keyword() | map(), timeout()) ::
              {:ok, connection()} | {:error, term()}

  @callback handshake(connection(), timeout()) ::
              {:ok, connection()} | {:error, term()}

  @callback connect(
              String.t() | :inet.ip_address(),
              :inet.port_number(),
              keyword() | map(),
              timeout()
            ) ::
              {:ok, connection()} | {:error, term()}

  @callback open_stream(connection(), opts :: keyword() | map()) ::
              {:ok, stream()} | {:error, term()}

  @callback accept_stream(connection(), opts :: keyword() | map(), timeout()) ::
              {:ok, stream()} | {:error, term()}

  @callback send_stream(stream(), iodata(), opts :: keyword() | map()) ::
              :ok | {:error, term()}

  @callback recv_stream(stream(), byte_count :: non_neg_integer()) ::
              {:ok, binary()} | {:error, term()}

  @callback send_datagram(connection(), binary()) :: :ok | {:error, term()}

  @callback send_datagram(connection(), binary(), opts :: keyword() | map()) ::
              :ok | {:error, term()}

  @callback finish_sending(stream()) :: :ok | {:error, term()}

  @callback abort_sending(stream(), non_neg_integer()) :: :ok | {:error, term()}

  @callback abort_receiving(stream(), non_neg_integer()) :: :ok | {:error, term()}

  @callback close_connection(connection(), non_neg_integer()) :: :ok | {:error, term()}

  @callback set_active(stream(), boolean() | :once | non_neg_integer()) :: :ok | {:error, term()}

  @callback controlling_process(listener() | connection() | stream(), pid()) ::
              :ok | {:error, term()}

  @callback normalize_message(term()) :: event() | :unknown

  @callback stream_info(stream(), :client | :server, :local | :peer) ::
              {:ok, Info.t()} | {:error, term()}

  @callback capabilities(connection()) :: MOQX.Transport.Capabilities.t() | {:error, term()}

  @optional_callbacks close_listener: 2, local_address: 1, stream_info: 3, send_datagram: 3

  @doc """
  Creates caller-owned transport context for backend module.
  """
  @spec new(module(), keyword() | map()) :: {:ok, Context.t()} | {:error, term()}
  def new(backend, opts \\ []) when is_atom(backend) do
    data = %{
      opts: opts,
      listeners: %{},
      connections: %{},
      streams: %{},
      stream_counters: %{},
      pending_peer_streams: :queue.new()
    }

    {:ok, %Context{backend: %BackendRef{module: backend, data: data}}}
  end

  @doc """
  Starts listener through context backend.
  """
  def listen(%Context{} = ctx, port, opts \\ []) do
    backend = ctx.backend.module
    call_opts = merge_backend_opts(ctx, opts)

    case backend.listen(port, call_opts) do
      {:ok, raw_listener} ->
        listener = %Listener{
          backend: %BackendRef{module: backend, data: raw_listener},
          local_role: :server,
          port: listener_port(backend, raw_listener)
        }

        {:ok, listener, put_resource(ctx, :listeners, raw_listener, listener)}

      {:error, reason} ->
        {:error, reason, ctx}
    end
  end

  @doc """
  Returns local address for listener or connection where backend supports it.
  """
  def local_address(%Context{} = ctx, %Listener{} = listener) do
    require_same_backend(ctx, listener, fn ->
      backend_local_address(ctx.backend.module, listener.backend.data)
    end)
  end

  def local_address(%Context{} = ctx, %Conn{} = connection) do
    require_same_backend(ctx, connection, fn ->
      backend_local_address(ctx.backend.module, connection.backend.data)
    end)
  end

  @doc """
  Closes listener where backend supports it.
  """
  def close_listener(%Context{} = ctx, %Listener{} = listener, timeout \\ 0) do
    require_same_backend(ctx, listener, fn ->
      close_backend_listener(ctx, listener.backend.data, timeout)
    end)
  end

  @doc """
  Connects client connection through context backend.
  """
  def connect(%Context{} = ctx, host, port, opts \\ [], timeout \\ 5_000) do
    backend = ctx.backend.module
    call_opts = merge_backend_opts(ctx, opts)

    case backend.connect(host, port, call_opts, timeout) do
      {:ok, raw_connection} ->
        connection = wrap_connection(backend, raw_connection, :client)
        {:ok, connection, put_resource(ctx, :connections, raw_connection, connection)}

      {:error, reason} ->
        {:error, reason, ctx}

      {:error, reason, details} ->
        {:error, {reason, details}, ctx}
    end
  end

  @doc """
  Accepts server connection from listener.
  """
  def accept(%Context{} = ctx, %Listener{} = listener, opts \\ [], timeout \\ :infinity) do
    require_same_backend(ctx, listener, fn ->
      backend = ctx.backend.module

      case backend.accept(listener.backend.data, opts, timeout) do
        {:ok, raw_connection} ->
          connection = wrap_connection(backend, raw_connection, :server)
          {:ok, connection, put_resource(ctx, :connections, raw_connection, connection)}

        {:error, reason} ->
          {:error, reason, ctx}
      end
    end)
  end

  @doc """
  Completes backend handshake.
  """
  def handshake(%Context{} = ctx, %Conn{} = connection, timeout \\ 5_000) do
    require_same_backend(ctx, connection, fn ->
      backend = ctx.backend.module

      case backend.handshake(connection.backend.data, timeout) do
        {:ok, raw_connection} ->
          updated = %{connection | backend: %BackendRef{module: backend, data: raw_connection}}
          {:ok, updated, put_resource(ctx, :connections, raw_connection, updated)}

        {:error, reason} ->
          {:error, reason, ctx}
      end
    end)
  end

  @doc """
  Opens local stream and records exact stream metadata.
  """
  def open_stream(%Context{} = ctx, %Conn{} = connection, opts \\ []) do
    require_same_backend(ctx, connection, fn ->
      backend = ctx.backend.module
      direction = option(opts, :direction, :bidirectional)

      case backend.open_stream(connection.backend.data, opts) do
        {:ok, raw_stream} ->
          open_stream_result(ctx, backend, connection, raw_stream, direction)

        {:error, reason} ->
          {:error, reason, ctx}
      end
    end)
  end

  @doc """
  Accepts peer stream and records exact stream metadata.
  """
  def accept_stream(
        %Context{} = ctx,
        %Conn{} = connection,
        opts \\ [],
        timeout \\ :infinity
      ) do
    require_same_backend(ctx, connection, fn ->
      backend = ctx.backend.module

      case backend.accept_stream(connection.backend.data, opts, timeout) do
        {:ok, raw_stream} ->
          accept_stream_result(ctx, backend, connection, raw_stream)

        {:error, reason} ->
          {:error, reason, ctx}
      end
    end)
  end

  @doc """
  Schedules bytes on stream from the context owner.

  Returns a send token once the backend accepts the send request. Context-owned
  receive loops can observe later completion or cancellation events, but token
  correlation is stream-local. Use `MOQX.Transport.Conn.Stream.Sender` when the
  caller needs completion feedback as backend credit for accepted sends.

  Pass `finish: true` to attach FIN to this accepted payload.
  """
  def send_stream(ctx, stream, data, opts \\ [])

  def send_stream(%Context{} = ctx, %Stream{info: %{send_side?: false}} = stream, data, opts) do
    started_at = monotonic_us()
    result = {:error, :send_side_unavailable, ctx}

    emit_stream_send_stop(ctx, stream, data, opts, started_at, result)
    result
  end

  def send_stream(%Context{} = ctx, %Stream{} = stream, data, opts) do
    started_at = monotonic_us()

    result =
      require_same_backend(ctx, stream, fn ->
        schedule_stream_send(ctx, stream.backend.data, data, opts)
      end)

    emit_stream_send_stop(ctx, stream, data, opts, started_at, result)
    result
  end

  defp schedule_stream_send(ctx, raw_stream, data, opts) do
    send = build_send(data, opts)
    accept_stream_send(ctx, raw_stream, data, opts, send)
  end

  defp accept_stream_send(ctx, raw_stream, data, opts, send) do
    case ctx.backend.module.send_stream(raw_stream, data, opts) do
      :ok ->
        {:ok, send, ctx}

      {:error, reason} ->
        {:error, reason, ctx}
    end
  end

  defp build_send(data, opts) do
    %Send{
      ref: make_ref(),
      byte_size: :erlang.iolist_size(data),
      finish?: option(opts, :finish, false) == true
    }
  end

  @doc false
  def send_stream_sender(
        %Sender{stream: %Stream{info: %{send_side?: false}}} = sender,
        data,
        opts
      ) do
    started_at = monotonic_us()
    result = {:error, :send_side_unavailable, sender}

    emit_stream_send_stop(sender, data, opts, started_at, result)
    result
  end

  def send_stream_sender(%Sender{finished_sending?: true} = sender, data, opts) do
    started_at = monotonic_us()
    result = {:error, :send_side_finished, sender}

    emit_stream_send_stop(sender, data, opts, started_at, result)
    result
  end

  def send_stream_sender(%Sender{stream: %Stream{} = stream} = sender, data, opts) do
    started_at = monotonic_us()
    send = build_send(data, opts)

    result =
      case stream.backend.module.send_stream(stream.backend.data, data, opts) do
        :ok ->
          sender =
            sender
            |> enqueue_sender_send(send)
            |> maybe_mark_sender_finished(send.finish?)

          {:ok, send, sender}

        {:error, reason} ->
          {:error, reason, sender}
      end

    emit_stream_send_stop(sender, data, opts, started_at, result)
    result
  end

  @doc false
  def receive_stream_event(%Sender{} = sender, timeout \\ :infinity) do
    started_at = monotonic_us()

    result =
      receive do
        message -> normalize_stream_sender_message(sender, message)
      after
        timeout_value(timeout) -> {:timeout, sender}
      end

    emit_receive_stream_event_stop(sender, timeout, started_at, result)
    result
  end

  defp enqueue_sender_send(%Sender{} = sender, %Send{} = send) do
    %{sender | pending_sends: :queue.in(send, sender.pending_sends)}
  end

  defp maybe_mark_sender_finished(%Sender{} = sender, true),
    do: %{sender | finished_sending?: true}

  defp maybe_mark_sender_finished(%Sender{} = sender, false), do: sender

  defp pop_sender_send(%Sender{} = sender) do
    case :queue.out(sender.pending_sends) do
      {{:value, send}, remaining} -> {{:ok, send}, %{sender | pending_sends: remaining}}
      {:empty, _queue} -> {{:error, nil}, sender}
    end
  end

  @doc """
  Receives bytes from stream in passive mode.
  """
  def recv_stream(%Context{} = ctx, %Stream{info: %{receive_side?: false}} = stream, byte_count) do
    started_at = monotonic_us()
    result = {:error, :receive_side_unavailable, ctx}

    emit_stream_recv_stop(ctx, stream, byte_count, started_at, result)
    result
  end

  def recv_stream(%Context{} = ctx, %Stream{} = stream, byte_count) do
    started_at = monotonic_us()

    result =
      require_same_backend(ctx, stream, fn ->
        case ctx.backend.module.recv_stream(stream.backend.data, byte_count) do
          {:ok, data} -> {:ok, data, ctx}
          {:error, reason} -> {:error, reason, ctx}
        end
      end)

    emit_stream_recv_stop(ctx, stream, byte_count, started_at, result)
    result
  end

  @doc """
  Configures active stream delivery.
  """
  def set_active(%Context{} = ctx, %Stream{} = stream, active) do
    require_same_backend(ctx, stream, fn ->
      case ctx.backend.module.set_active(stream.backend.data, active) do
        :ok -> {:ok, ctx}
        {:error, reason} -> {:error, reason, ctx}
      end
    end)
  end

  @doc """
  Schedules an unreliable datagram on connection.

  Completion, loss, or cancellation is reported asynchronously by backend
  connection events where available.
  """
  def send_datagram(%Context{} = ctx, %Conn{} = connection, data) when is_binary(data) do
    started_at = monotonic_us()

    result =
      require_same_backend(ctx, connection, fn ->
        case backend_send_datagram(
               ctx.backend.module,
               connection.backend.data,
               data,
               ctx.backend.data.opts
             ) do
          :ok -> {:ok, ctx}
          {:error, reason} -> {:error, reason, ctx}
        end
      end)

    emit_datagram_send_stop(ctx, connection, data, started_at, result)
    result
  end

  @doc """
  Gracefully finishes local send side of stream.

  Intent: caller has sent all bytes successfully.
  QUIC mapping: FIN.
  Peer observation: peer receives `:peer_finished_sending`.
  Completion: returns after backend accepts request; lifecycle events arrive later.
  """
  def finish_sending(%Context{} = ctx, %Stream{info: %{send_side?: false}}) do
    {:error, :send_side_unavailable, ctx}
  end

  def finish_sending(%Context{} = ctx, %Stream{} = stream) do
    call_stream_shutdown(ctx, stream, :finish_sending, [])
  end

  @doc """
  Aborts local send side of stream.

  Intent: caller cannot or will not finish sending bytes.
  QUIC mapping: RESET_STREAM with application error code.
  Peer observation: peer receives `:peer_aborted_sending`.
  Completion: returns after backend accepts request; lifecycle events arrive later.
  """
  def abort_sending(%Context{} = ctx, %Stream{info: %{send_side?: false}}, error_code)
      when is_integer(error_code) and error_code >= 0 do
    {:error, :send_side_unavailable, ctx}
  end

  def abort_sending(%Context{} = ctx, %Stream{} = stream, error_code)
      when is_integer(error_code) and error_code >= 0 do
    call_stream_shutdown(ctx, stream, :abort_sending, [error_code])
  end

  @doc """
  Aborts local receive side of stream.

  Intent: caller no longer wants to receive bytes on this stream.
  QUIC mapping: STOP_SENDING with application error code.
  Peer observation: peer receives `:peer_aborted_receiving`.
  Completion: returns after backend accepts request; lifecycle events arrive later.
  """
  def abort_receiving(%Context{} = ctx, %Stream{info: %{receive_side?: false}}, error_code)
      when is_integer(error_code) and error_code >= 0 do
    {:error, :receive_side_unavailable, ctx}
  end

  def abort_receiving(%Context{} = ctx, %Stream{} = stream, error_code)
      when is_integer(error_code) and error_code >= 0 do
    call_stream_shutdown(ctx, stream, :abort_receiving, [error_code])
  end

  @doc """
  Closes connection with application error code.

  Intent: caller closes whole transport connection.
  QUIC mapping: CONNECTION_CLOSE with application error code.
  Peer observation: peer receives connection `:closed` event where backend exposes it.
  Completion: returns after backend accepts request; lifecycle events arrive later.
  """
  def close_connection(%Context{} = ctx, %Conn{} = connection, error_code)
      when is_integer(error_code) and error_code >= 0 do
    require_same_backend(ctx, connection, fn ->
      case ctx.backend.module.close_connection(connection.backend.data, error_code) do
        :ok -> {:ok, ctx}
        {:error, reason} -> {:error, reason, ctx}
      end
    end)
  end

  @doc """
  Returns exact metadata for a stream wrapper.
  """
  def stream_info(%Context{} = ctx, %Stream{} = stream) do
    require_same_backend(ctx, stream, fn -> {:ok, stream.info, ctx} end)
  end

  @doc """
  Returns normalized capabilities for a negotiated transport connection.
  """
  def capabilities(%Context{} = ctx, %Conn{} = connection) do
    case same_backend(ctx, connection) do
      :ok -> ctx.backend.module.capabilities(connection.backend.data)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transfers ownership of every known backend handle in context to `pid`.
  """
  def controlling_process(%Context{} = ctx, pid) when is_pid(pid) do
    handles =
      ctx.backend.data.listeners
      |> Map.keys()
      |> Kernel.++(Map.keys(ctx.backend.data.connections))
      |> Kernel.++(Map.keys(ctx.backend.data.streams))

    case transfer_all(ctx.backend.module, handles, pid, []) do
      :ok -> {:ok, ctx}
      {:error, failures} -> {:error, {:handoff_failed, failures}, ctx}
    end
  end

  @doc """
  Receives one backend message and normalizes it through context backend.
  """
  def receive_event(ctx, timeout \\ :infinity)

  def receive_event(%Context{} = ctx, timeout) do
    started_at = monotonic_us()

    result =
      receive do
        message -> normalize_context_message(ctx, message)
      after
        timeout_value(timeout) -> {:timeout, ctx}
      end

    emit_receive_event_stop(ctx, timeout, started_at, result)
    result
  end

  @doc """
  Normalizes one already-received backend message through a caller-owned context.

  This is the non-blocking counterpart to `receive_event/2` for process runtimes
  whose receive loop already removed the message from the mailbox.
  """
  @spec normalize_event(Context.t(), term()) ::
          {:ok, event(), Context.t()}
          | {:error, term(), Context.t()}
          | {:unknown, term(), Context.t()}
  def normalize_event(%Context{} = ctx, message), do: normalize_context_message(ctx, message)

  @doc """
  Normalizes a message for a known connection, adopting a peer-created stream
  when an active backend reports `:new_stream` before `accept_stream/4` runs.
  """
  @spec normalize_event(Context.t(), Conn.t(), term()) ::
          {:ok, event(), Context.t()}
          | {:error, term(), Context.t()}
          | {:unknown, term(), Context.t()}
  def normalize_event(%Context{} = ctx, %Conn{} = connection, message) do
    case normalize_context_message(ctx, message) do
      {:error, {:unknown_transport_handle, raw_stream}, ^ctx} ->
        adopt_peer_stream_event(ctx, connection, message, raw_stream)

      result ->
        result
    end
  end

  defp timeout_value(:infinity), do: :infinity
  defp timeout_value(timeout), do: timeout

  defp open_stream_result(ctx, backend, connection, raw_stream, direction) do
    {stream_id, ctx} = allocate_stream_id(ctx, connection.local_role, direction)

    info =
      stream_info_from_parts(
        stream_id,
        direction,
        :local,
        connection.local_role,
        connection.local_role
      )

    stream = %Stream{backend: %BackendRef{module: backend, data: raw_stream}, info: info}

    ctx =
      ctx
      |> put_resource(:streams, raw_stream, stream)
      |> enqueue_pending_peer_stream(stream_id, direction, connection.local_role)

    {:ok, stream, ctx}
  end

  defp accept_stream_result(ctx, backend, connection, raw_stream) do
    case dequeue_pending_peer_stream(ctx, peer_role(connection.local_role)) do
      {:ok, {stream_id, direction, initiator_role}, ctx} ->
        case backend_stream_direction(backend, raw_stream, connection.local_role) do
          {:ok, ^direction} ->
            stream =
              accepted_stream(
                backend,
                raw_stream,
                stream_id,
                direction,
                initiator_role,
                connection
              )

            {:ok, stream, put_resource(ctx, :streams, raw_stream, stream)}

          {:ok, _other_direction} ->
            accept_stream_from_backend_info(ctx, backend, connection, raw_stream)

          :unavailable ->
            stream =
              accepted_stream(
                backend,
                raw_stream,
                stream_id,
                direction,
                initiator_role,
                connection
              )

            {:ok, stream, put_resource(ctx, :streams, raw_stream, stream)}
        end

      {:error, _reason, ctx} ->
        accept_stream_from_backend_info(ctx, backend, connection, raw_stream)
    end
  end

  defp backend_stream_direction(backend, raw_stream, local_role) do
    if function_exported?(backend, :stream_info, 3) do
      case backend.stream_info(raw_stream, local_role, :peer) do
        {:ok, %Info{direction: direction}} -> {:ok, direction}
        {:error, _reason} -> :unavailable
      end
    else
      :unavailable
    end
  end

  defp accept_stream_from_backend_info(ctx, backend, connection, raw_stream) do
    if function_exported?(backend, :stream_info, 3) do
      case backend.stream_info(raw_stream, connection.local_role, :peer) do
        {:ok, info} ->
          stream = %Stream{backend: %BackendRef{module: backend, data: raw_stream}, info: info}
          {:ok, stream, put_resource(ctx, :streams, raw_stream, stream)}

        {:error, reason} ->
          {:error, reason, ctx}
      end
    else
      {:error, {:unknown_transport_handle, raw_stream}, ctx}
    end
  end

  defp accepted_stream(backend, raw_stream, stream_id, direction, initiator_role, connection) do
    info =
      stream_info_for_backend(
        backend,
        raw_stream,
        stream_id,
        direction,
        :peer,
        initiator_role,
        connection.local_role
      )

    %Stream{backend: %BackendRef{module: backend, data: raw_stream}, info: info}
  end

  defp stream_info_for_backend(
         backend,
         raw_stream,
         stream_id,
         direction,
         initiator,
         initiator_role,
         local_role
       ) do
    if function_exported?(backend, :stream_info, 3) do
      case backend.stream_info(raw_stream, local_role, initiator) do
        {:ok, info} ->
          info

        {:error, _reason} ->
          stream_info_from_parts(stream_id, direction, initiator, initiator_role, local_role)
      end
    else
      stream_info_from_parts(stream_id, direction, initiator, initiator_role, local_role)
    end
  end

  defp merge_backend_opts(%Context{backend: %BackendRef{data: %{opts: default_opts}}}, opts) do
    merge_opts(default_opts, opts)
  end

  defp merge_opts(default_opts, opts) when is_list(default_opts) and is_list(opts),
    do: Keyword.merge(default_opts, opts)

  defp merge_opts(default_opts, opts) when is_map(default_opts) and is_map(opts),
    do: Map.merge(default_opts, opts)

  defp merge_opts(default_opts, opts) when is_list(default_opts) and is_map(opts),
    do: Map.merge(Map.new(default_opts), opts)

  defp merge_opts(default_opts, opts) when is_map(default_opts) and is_list(opts),
    do: Map.merge(default_opts, Map.new(opts))

  defp listener_port(backend, raw_listener) do
    case backend_local_address(backend, raw_listener) do
      {:ok, {_ip, port}} -> port
      {:error, _reason} -> nil
    end
  end

  defp backend_local_address(backend, raw_handle) do
    if backend_exports?(backend, :local_address, 1) do
      backend.local_address(raw_handle)
    else
      {:error, :unsupported}
    end
  end

  defp backend_exports?(backend, function, arity) do
    Code.ensure_loaded?(backend) and function_exported?(backend, function, arity)
  end

  defp close_backend_listener(ctx, raw_listener, timeout) do
    if backend_exports?(ctx.backend.module, :close_listener, 2) do
      close_exported_listener(ctx, raw_listener, timeout)
    else
      {:error, :unsupported, ctx}
    end
  end

  defp close_exported_listener(ctx, raw_listener, timeout) do
    case ctx.backend.module.close_listener(raw_listener, timeout) do
      :ok -> {:ok, ctx}
      {:error, reason} -> {:error, reason, ctx}
    end
  end

  defp backend_send_datagram(backend, raw_connection, data, opts) do
    if backend_exports?(backend, :send_datagram, 3) do
      backend.send_datagram(raw_connection, data, opts)
    else
      backend.send_datagram(raw_connection, data)
    end
  end

  defp wrap_connection(backend, raw_connection, role) do
    %Conn{backend: %BackendRef{module: backend, data: raw_connection}, local_role: role}
  end

  defp same_backend(%Context{backend: %BackendRef{module: module}}, %{
         backend: %BackendRef{module: module}
       }),
       do: :ok

  defp same_backend(_ctx, _handle), do: {:error, :backend_mismatch}

  defp require_same_backend(ctx, handle, fun) do
    case same_backend(ctx, handle) do
      :ok -> fun.()
      {:error, reason} -> {:error, reason, ctx}
    end
  end

  defp put_resource(ctx, kind, raw, wrapper) do
    update_backend_data(ctx, fn data ->
      update_in(data, [kind], &Map.put(&1, raw, wrapper))
    end)
  end

  defp update_backend_data(%Context{} = ctx, fun) do
    %{ctx | backend: %{ctx.backend | data: fun.(ctx.backend.data)}}
  end

  defp normalize_context_message(ctx, {:moqx_transport, event}) do
    case wrap_event(ctx, event) do
      {:ok, event, ctx} -> {:ok, event, ctx}
      {:error, reason} -> {:error, reason, ctx}
    end
  end

  defp normalize_context_message(ctx, message) do
    case ctx.backend.module.normalize_message(message) do
      :unknown ->
        {:unknown, message, ctx}

      event ->
        case wrap_event(ctx, event) do
          {:ok, event, ctx} -> {:ok, event, ctx}
          {:error, reason} -> {:error, reason, ctx}
        end
    end
  end

  defp adopt_peer_stream_event(ctx, connection, message, raw_stream) do
    case ctx.backend.module.normalize_message(message) do
      {:stream_event, ^raw_stream, :new_stream, metadata} ->
        case accept_stream_result(ctx, ctx.backend.module, connection, raw_stream) do
          {:ok, stream, ctx} -> {:ok, {:stream_event, stream, :new_stream, metadata}, ctx}
          {:error, reason, ctx} -> {:error, reason, ctx}
        end

      _event ->
        {:error, {:unknown_transport_handle, raw_stream}, ctx}
    end
  end

  defp normalize_stream_sender_message(%Sender{} = sender, {:moqx_transport, event}) do
    wrap_stream_sender_event(sender, event)
  end

  defp normalize_stream_sender_message(%Sender{stream: stream} = sender, message) do
    case stream.backend.module.normalize_message(message) do
      :unknown -> {:unknown, message, sender}
      event -> wrap_stream_sender_event(sender, event)
    end
  end

  defp transfer_all(_backend, [], _pid, []), do: :ok
  defp transfer_all(_backend, [], _pid, failures), do: {:error, Enum.reverse(failures)}

  defp transfer_all(backend, [handle | rest], pid, failures) do
    case backend.controlling_process(handle, pid) do
      :ok -> transfer_all(backend, rest, pid, failures)
      {:error, reason} -> transfer_all(backend, rest, pid, [{handle, reason} | failures])
    end
  end

  defp call_stream_shutdown(ctx, stream, function, args) do
    require_same_backend(ctx, stream, fn ->
      result = apply(ctx.backend.module, function, [stream.backend.data | args])

      case result do
        :ok ->
          {:ok, ctx}

        {:error, reason} ->
          {:error, reason, ctx}
      end
    end)
  end

  defp wrap_event(ctx, {:stream_event, raw_stream, :send_complete, cancelled?}) do
    case Map.fetch(ctx.backend.data.streams, raw_stream) do
      {:ok, stream} ->
        {event, metadata} = send_completion_event(cancelled?, :error, nil)
        {:ok, {:stream_event, stream, event, metadata}, ctx}

      :error ->
        {:error, {:unknown_transport_handle, raw_stream}}
    end
  end

  defp wrap_event(ctx, {:stream_event, raw_stream, event, metadata}) do
    case Map.fetch(ctx.backend.data.streams, raw_stream) do
      {:ok, stream} -> {:ok, {:stream_event, stream, event, metadata}, ctx}
      :error -> {:error, {:unknown_transport_handle, raw_stream}}
    end
  end

  defp wrap_event(ctx, {:stream_data, raw_stream, data, metadata}) do
    case Map.fetch(ctx.backend.data.streams, raw_stream) do
      {:ok, stream} -> {:ok, {:stream_data, stream, data, metadata}, ctx}
      :error -> {:error, {:unknown_transport_handle, raw_stream}}
    end
  end

  defp wrap_event(ctx, {:datagram, raw_connection, data, metadata}) do
    case Map.fetch(ctx.backend.data.connections, raw_connection) do
      {:ok, connection} -> {:ok, {:datagram, connection, data, metadata}, ctx}
      :error -> {:error, {:unknown_transport_handle, raw_connection}}
    end
  end

  defp wrap_event(ctx, {:connection_event, raw_connection, event, metadata}) do
    case Map.fetch(ctx.backend.data.connections, raw_connection) do
      {:ok, connection} -> {:ok, {:connection_event, connection, event, metadata}, ctx}
      :error -> {:error, {:unknown_transport_handle, raw_connection}}
    end
  end

  defp wrap_event(ctx, {:listener_event, raw_handle, event, metadata}) do
    case fetch_listener_event_handle(ctx, raw_handle) do
      {:ok, handle} -> {:ok, {:listener_event, handle, event, metadata}, ctx}
      :error -> {:error, {:unknown_transport_handle, raw_handle}}
    end
  end

  defp wrap_event(ctx, event), do: {:ok, event, ctx}

  defp wrap_stream_sender_event(
         %Sender{stream: %Stream{backend: %BackendRef{data: raw_stream}} = stream} = sender,
         {:stream_event, raw_stream, :send_complete, cancelled?}
       ) do
    {{status, send}, sender} = pop_sender_send(sender)
    {event, metadata} = send_completion_event(cancelled?, status, send)
    {:ok, {:stream_event, stream, event, metadata}, sender}
  end

  defp wrap_stream_sender_event(
         %Sender{stream: %Stream{backend: %BackendRef{data: raw_stream}} = stream} = sender,
         {:stream_event, raw_stream, event, metadata}
       ) do
    {:ok, {:stream_event, stream, event, metadata}, sender}
  end

  defp wrap_stream_sender_event(
         %Sender{stream: %Stream{backend: %BackendRef{data: raw_stream}} = stream} = sender,
         {:stream_data, raw_stream, data, metadata}
       ) do
    {:ok, {:stream_data, stream, data, metadata}, sender}
  end

  defp wrap_stream_sender_event(
         %Sender{} = sender,
         {:stream_event, raw_stream, _event, _metadata}
       ) do
    {:error, {:unknown_transport_handle, raw_stream}, sender}
  end

  defp wrap_stream_sender_event(%Sender{} = sender, {:stream_data, raw_stream, _data, _metadata}) do
    {:error, {:unknown_transport_handle, raw_stream}, sender}
  end

  defp wrap_stream_sender_event(%Sender{} = sender, event), do: {:unknown, event, sender}

  defp send_completion_event(false, :ok, send) do
    {:send_completed, send_completion_metadata(send, false)}
  end

  defp send_completion_event(true, :ok, send) do
    {:send_cancelled, send_completion_metadata(send, true)}
  end

  defp send_completion_event(cancelled?, :error, _send) do
    event = if cancelled?, do: :send_cancelled, else: :send_completed
    {event, %{orphan?: true, cancelled?: cancelled?}}
  end

  defp send_completion_metadata(%Send{} = send, cancelled?) do
    %{
      send: send,
      ref: send.ref,
      byte_size: send.byte_size,
      finish?: send.finish?,
      cancelled?: cancelled?
    }
  end

  defp fetch_listener_event_handle(ctx, raw_handle) do
    case Map.fetch(ctx.backend.data.listeners, raw_handle) do
      {:ok, listener} -> {:ok, listener}
      :error -> Map.fetch(ctx.backend.data.connections, raw_handle)
    end
  end

  defp allocate_stream_id(ctx, initiator_role, direction) do
    key = {initiator_role, direction}
    index = Map.get(ctx.backend.data.stream_counters, key, 0)
    stream_id = index * 4 + role_bit(initiator_role) + direction_bit(direction)

    ctx =
      update_backend_data(ctx, fn data ->
        put_in(data, [:stream_counters, key], index + 1)
      end)

    {stream_id, ctx}
  end

  defp enqueue_pending_peer_stream(ctx, stream_id, direction, initiator_role) do
    update_backend_data(ctx, fn data ->
      Map.update!(
        data,
        :pending_peer_streams,
        &:queue.in({stream_id, direction, initiator_role}, &1)
      )
    end)
  end

  defp dequeue_pending_peer_stream(ctx, initiator_role) do
    {match, remaining} =
      pop_pending_peer_stream(ctx.backend.data.pending_peer_streams, initiator_role)

    ctx = update_backend_data(ctx, &Map.put(&1, :pending_peer_streams, remaining))

    case match do
      nil -> {:error, {:unknown_transport_handle, :stream}, ctx}
      value -> {:ok, value, ctx}
    end
  end

  defp pop_pending_peer_stream(queue, initiator_role) do
    queue
    |> :queue.to_list()
    |> pop_first(initiator_role, [])
  end

  defp pop_first([], _initiator_role, kept), do: {nil, :queue.from_list(Enum.reverse(kept))}

  defp pop_first([{_id, _direction, initiator_role} = item | rest], initiator_role, kept) do
    {item, :queue.from_list(Enum.reverse(kept) ++ rest)}
  end

  defp pop_first([item | rest], initiator_role, kept),
    do: pop_first(rest, initiator_role, [item | kept])

  defp stream_info_from_parts(stream_id, direction, initiator, initiator_role, local_role) do
    %Info{
      stream_id: stream_id,
      direction: direction,
      initiator: initiator,
      initiator_role: initiator_role,
      local_role: local_role,
      send_side?: send_side?(direction, initiator),
      receive_side?: receive_side?(direction, initiator)
    }
  end

  defp send_side?(:bidirectional, _initiator), do: true
  defp send_side?(:unidirectional, :local), do: true
  defp send_side?(:unidirectional, :peer), do: false

  defp receive_side?(:bidirectional, _initiator), do: true
  defp receive_side?(:unidirectional, :local), do: false
  defp receive_side?(:unidirectional, :peer), do: true

  defp peer_role(:client), do: :server
  defp peer_role(:server), do: :client

  defp role_bit(:client), do: 0
  defp role_bit(:server), do: 1

  defp direction_bit(:bidirectional), do: 0
  defp direction_bit(:unidirectional), do: 2

  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp emit_stream_send_stop(ctx, stream, data, opts, started_at, result) do
    measurements =
      %{
        duration_us: monotonic_us() - started_at,
        byte_size: stream_send_byte_size(result, data)
      }
      |> compact_measurements()

    metadata =
      stream_metadata(ctx, stream)
      |> Map.merge(result_metadata(result))
      |> Map.put(:finish?, option(opts, :finish, false) == true)
      |> Map.put(:sender_topology, :context_owner)

    :telemetry.execute([:moqx, :transport, :stream, :send, :stop], measurements, metadata)
  end

  defp emit_stream_send_stop(%Sender{stream: stream}, data, opts, started_at, result) do
    measurements =
      %{
        duration_us: monotonic_us() - started_at,
        byte_size: stream_send_byte_size(result, data)
      }
      |> compact_measurements()

    metadata =
      stream_metadata_with_backend(stream)
      |> Map.merge(result_metadata(result))
      |> Map.put(:finish?, option(opts, :finish, false) == true)
      |> Map.put(:sender_topology, :stream_owner)

    :telemetry.execute([:moqx, :transport, :stream, :send, :stop], measurements, metadata)
  end

  defp stream_send_byte_size({:ok, %Send{byte_size: byte_size}, _ctx}, _data), do: byte_size
  defp stream_send_byte_size(_result, data), do: safe_iodata_size(data)

  defp emit_stream_recv_stop(ctx, stream, byte_count, started_at, result) do
    measurements =
      %{
        duration_us: monotonic_us() - started_at,
        requested_byte_count: byte_count,
        byte_size: stream_recv_byte_size(result)
      }
      |> compact_measurements()

    metadata =
      stream_metadata(ctx, stream)
      |> Map.merge(result_metadata(result))

    :telemetry.execute([:moqx, :transport, :stream, :recv, :stop], measurements, metadata)
  end

  defp stream_recv_byte_size({:ok, data, _ctx}), do: byte_size(data)
  defp stream_recv_byte_size(_result), do: nil

  defp emit_datagram_send_stop(ctx, connection, data, started_at, result) do
    measurements = %{
      duration_us: monotonic_us() - started_at,
      byte_size: byte_size(data)
    }

    metadata =
      connection_metadata(ctx, connection)
      |> Map.merge(result_metadata(result))

    :telemetry.execute([:moqx, :transport, :datagram, :send, :stop], measurements, metadata)
  end

  defp emit_receive_event_stop(ctx, timeout, started_at, result) do
    measurements =
      %{
        duration_us: monotonic_us() - started_at,
        timeout_ms: telemetry_timeout_ms(timeout),
        byte_size: receive_event_byte_size(result)
      }
      |> compact_measurements()

    metadata =
      %{backend: ctx.backend.module}
      |> Map.merge(receive_result_metadata(result))

    :telemetry.execute([:moqx, :transport, :event, :receive, :stop], measurements, metadata)
  end

  defp emit_receive_stream_event_stop(%Sender{stream: stream}, timeout, started_at, result) do
    measurements =
      %{
        duration_us: monotonic_us() - started_at,
        timeout_ms: telemetry_timeout_ms(timeout),
        byte_size: receive_event_byte_size(result)
      }
      |> compact_measurements()

    metadata =
      %{backend: stream.backend.module, receiver_topology: :stream_owner}
      |> Map.merge(receive_result_metadata(result))

    :telemetry.execute([:moqx, :transport, :event, :receive, :stop], measurements, metadata)
  end

  defp result_metadata({:ok, _value, _ctx}), do: %{result: :ok, reason: nil}
  defp result_metadata({:ok, _ctx}), do: %{result: :ok, reason: nil}

  defp result_metadata({:error, reason, _ctx}),
    do: %{result: :error, reason: telemetry_reason(reason)}

  defp receive_result_metadata({:ok, event, _ctx}) do
    event
    |> event_metadata()
    |> Map.merge(%{result: :ok, reason: nil})
  end

  defp receive_result_metadata({:timeout, _ctx}) do
    %{result: :timeout, event_kind: :timeout, event_name: nil, reason: nil}
  end

  defp receive_result_metadata({:unknown, _message, _ctx}) do
    %{result: :unknown, event_kind: :unknown, event_name: nil, reason: nil}
  end

  defp receive_result_metadata({:error, reason, _ctx}) do
    %{result: :error, event_kind: :error, event_name: nil, reason: telemetry_reason(reason)}
  end

  defp event_metadata({:stream_data, stream, _data, _metadata}) do
    stream_metadata(stream)
    |> Map.merge(%{event_kind: :stream_data, event_name: nil})
  end

  defp event_metadata({:datagram, connection, _data, _metadata}) do
    connection_metadata(connection)
    |> Map.merge(%{event_kind: :datagram, event_name: nil})
  end

  defp event_metadata({:stream_event, stream, event, _metadata}) do
    stream_metadata(stream)
    |> Map.merge(%{event_kind: :stream_event, event_name: event})
  end

  defp event_metadata({:connection_event, connection, event, _metadata}) do
    connection_metadata(connection)
    |> Map.merge(%{event_kind: :connection_event, event_name: event})
  end

  defp event_metadata({:listener_event, _listener_or_connection, event, _metadata}) do
    %{event_kind: :listener_event, event_name: event}
  end

  defp event_metadata(_event), do: %{event_kind: :unknown, event_name: nil}

  defp stream_metadata(ctx, %Stream{} = stream) do
    %{backend: ctx.backend.module}
    |> Map.merge(stream_metadata(stream))
  end

  defp stream_metadata_with_backend(%Stream{} = stream) do
    %{backend: stream.backend.module}
    |> Map.merge(stream_metadata(stream))
  end

  defp stream_metadata(%Stream{info: info}) do
    %{
      stream_id: info.stream_id,
      stream_direction: info.direction,
      stream_initiator: info.initiator,
      local_role: info.local_role
    }
  end

  defp connection_metadata(ctx, %Conn{} = connection) do
    %{backend: ctx.backend.module}
    |> Map.merge(connection_metadata(connection))
  end

  defp connection_metadata(%Conn{local_role: local_role}) do
    %{local_role: local_role}
  end

  defp receive_event_byte_size({:ok, {:stream_data, _stream, data, _metadata}, _ctx}),
    do: byte_size(data)

  defp receive_event_byte_size({:ok, {:datagram, _connection, data, _metadata}, _ctx}),
    do: byte_size(data)

  defp receive_event_byte_size(_result), do: nil

  defp telemetry_timeout_ms(:infinity), do: nil
  defp telemetry_timeout_ms(timeout), do: timeout

  defp safe_iodata_size(data) do
    :erlang.iolist_size(data)
  rescue
    _error -> nil
  end

  defp telemetry_reason({:unknown_transport_handle, _raw_handle}), do: :unknown_transport_handle

  defp telemetry_reason({reason, detail}) when is_atom(reason) and is_atom(detail),
    do: {reason, detail}

  defp telemetry_reason({reason, _details}) when is_atom(reason), do: reason
  defp telemetry_reason(reason) when is_atom(reason), do: reason
  defp telemetry_reason(_reason), do: :error

  defp compact_measurements(measurements) do
    Map.reject(measurements, fn {_key, value} -> is_nil(value) end)
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)
end
