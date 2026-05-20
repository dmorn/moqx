defmodule MOQX.Transport do
  @moduledoc """
  QUIC transport boundary for MOQT-family implementations.

  Protocol code should use this façade instead of backend modules directly.
  New code uses caller-owned `%MOQX.Transport.Context{}` values and opaque
  wrapper handles.
  """

  alias MOQX.Transport.{BackendRef, Connection, Context, Listener, Stream, StreamInfo}

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

  @callback finish_sending(stream()) :: :ok | {:error, term()}

  @callback abort_sending(stream(), non_neg_integer()) :: :ok | {:error, term()}

  @callback abort_receiving(stream(), non_neg_integer()) :: :ok | {:error, term()}

  @callback close_connection(connection(), non_neg_integer()) :: :ok | {:error, term()}

  @callback set_active(stream(), boolean() | :once | non_neg_integer()) :: :ok | {:error, term()}

  @callback controlling_process(listener() | connection() | stream(), pid()) ::
              :ok | {:error, term()}

  @callback normalize_message(term()) :: event() | :unknown

  @callback stream_info(stream(), :client | :server, :local | :peer) ::
              {:ok, StreamInfo.t()} | {:error, term()}

  @callback capabilities(connection()) :: MOQX.Transport.Capabilities.t() | {:error, term()}

  @optional_callbacks close_listener: 2, local_address: 1, stream_info: 3

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

  def local_address(%Context{} = ctx, %Connection{} = connection) do
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
  def handshake(%Context{} = ctx, %Connection{} = connection, timeout \\ 5_000) do
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
  def open_stream(%Context{} = ctx, %Connection{} = connection, opts \\ []) do
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
        %Connection{} = connection,
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
  Sends bytes on stream.
  """
  def send_stream(ctx, stream, data, opts \\ [])

  def send_stream(%Context{} = ctx, %Stream{info: %{send_side?: false}}, _data, _opts) do
    {:error, :send_side_unavailable, ctx}
  end

  def send_stream(%Context{} = ctx, %Stream{} = stream, data, opts) do
    require_same_backend(ctx, stream, fn ->
      case ctx.backend.module.send_stream(stream.backend.data, data, opts) do
        :ok -> {:ok, ctx}
        {:error, reason} -> {:error, reason, ctx}
      end
    end)
  end

  @doc """
  Receives bytes from stream in passive mode.
  """
  def recv_stream(%Context{} = ctx, %Stream{info: %{receive_side?: false}}, _byte_count) do
    {:error, :receive_side_unavailable, ctx}
  end

  def recv_stream(%Context{} = ctx, %Stream{} = stream, byte_count) do
    require_same_backend(ctx, stream, fn ->
      case ctx.backend.module.recv_stream(stream.backend.data, byte_count) do
        {:ok, data} -> {:ok, data, ctx}
        {:error, reason} -> {:error, reason, ctx}
      end
    end)
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
  def send_datagram(%Context{} = ctx, %Connection{} = connection, data) when is_binary(data) do
    require_same_backend(ctx, connection, fn ->
      case ctx.backend.module.send_datagram(connection.backend.data, data) do
        :ok -> {:ok, ctx}
        {:error, reason} -> {:error, reason, ctx}
      end
    end)
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
  def close_connection(%Context{} = ctx, %Connection{} = connection, error_code)
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
  def capabilities(%Context{} = ctx, %Connection{} = connection) do
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
    receive do
      message -> normalize_context_message(ctx, message)
    after
      timeout_value(timeout) -> {:timeout, ctx}
    end
  end

  defp timeout_value(:infinity), do: :infinity
  defp timeout_value(timeout), do: timeout

  defp open_stream_result(ctx, backend, connection, raw_stream, direction) do
    {stream_id, ctx} = allocate_stream_id(ctx, connection.local_role, direction)

    info =
      stream_info_for_backend(
        backend,
        raw_stream,
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
        stream =
          accepted_stream(backend, raw_stream, stream_id, direction, initiator_role, connection)

        {:ok, stream, put_resource(ctx, :streams, raw_stream, stream)}

      {:error, _reason, ctx} ->
        accept_stream_from_backend_info(ctx, backend, connection, raw_stream)
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

  defp wrap_connection(backend, raw_connection, role) do
    %Connection{backend: %BackendRef{module: backend, data: raw_connection}, local_role: role}
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
      {:ok, event} -> {:ok, event, ctx}
      {:error, reason} -> {:error, reason, ctx}
    end
  end

  defp normalize_context_message(ctx, message) do
    case ctx.backend.module.normalize_message(message) do
      :unknown ->
        {:unknown, message, ctx}

      event ->
        case wrap_event(ctx, event) do
          {:ok, event} -> {:ok, event, ctx}
          {:error, reason} -> {:error, reason, ctx}
        end
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
        :ok -> {:ok, ctx}
        {:error, reason} -> {:error, reason, ctx}
      end
    end)
  end

  defp wrap_event(ctx, {:stream_event, raw_stream, event, metadata}) do
    case Map.fetch(ctx.backend.data.streams, raw_stream) do
      {:ok, stream} -> {:ok, {:stream_event, stream, event, metadata}}
      :error -> {:error, {:unknown_transport_handle, raw_stream}}
    end
  end

  defp wrap_event(ctx, {:stream_data, raw_stream, data, metadata}) do
    case Map.fetch(ctx.backend.data.streams, raw_stream) do
      {:ok, stream} -> {:ok, {:stream_data, stream, data, metadata}}
      :error -> {:error, {:unknown_transport_handle, raw_stream}}
    end
  end

  defp wrap_event(ctx, {:datagram, raw_connection, data, metadata}) do
    case Map.fetch(ctx.backend.data.connections, raw_connection) do
      {:ok, connection} -> {:ok, {:datagram, connection, data, metadata}}
      :error -> {:error, {:unknown_transport_handle, raw_connection}}
    end
  end

  defp wrap_event(ctx, {:connection_event, raw_connection, event, metadata}) do
    case Map.fetch(ctx.backend.data.connections, raw_connection) do
      {:ok, connection} -> {:ok, {:connection_event, connection, event, metadata}}
      :error -> {:error, {:unknown_transport_handle, raw_connection}}
    end
  end

  defp wrap_event(ctx, {:listener_event, raw_handle, event, metadata}) do
    case fetch_listener_event_handle(ctx, raw_handle) do
      {:ok, handle} -> {:ok, {:listener_event, handle, event, metadata}}
      :error -> {:error, {:unknown_transport_handle, raw_handle}}
    end
  end

  defp wrap_event(_ctx, event), do: {:ok, event}

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
    %StreamInfo{
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
end
