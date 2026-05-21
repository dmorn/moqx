defmodule MOQX.Transport.Support do
  @moduledoc false

  @behaviour MOQX.Transport

  alias MOQX.Transport.{Capabilities, Profile}

  defmodule Network do
    @moduledoc false
    @opaque t :: %__MODULE__{pid: pid()}
    defstruct [:pid]
  end

  defmodule Listener do
    @moduledoc false
    @opaque t :: %__MODULE__{
              pid: pid(),
              network: Network.t() | nil,
              port: non_neg_integer() | nil,
              capabilities: Capabilities.t() | nil
            }
    defstruct [:pid, :network, :port, :capabilities]
  end

  defmodule Connection do
    @moduledoc false
    @opaque t :: %__MODULE__{pid: pid()}
    defstruct [:pid]
  end

  defmodule Stream do
    @moduledoc false
    @opaque t :: %__MODULE__{pid: pid()}
    defstruct [:pid]
  end

  @impl true
  def listen(port, opts) do
    with {:ok, network} <- fetch_network(opts),
         {:ok, capabilities} <- profile_capabilities(option(opts, :profile, :draft_14)) do
      listener_pid = spawn(fn -> listener_loop(:queue.new(), :queue.new(), nil, nil) end)
      ref = make_ref()
      send(network.pid, {:listen, self(), ref, port, listener_pid, capabilities})

      receive do
        {^ref, {:ok, bound_port}} ->
          listener = %Listener{
            pid: listener_pid,
            network: network,
            port: bound_port,
            capabilities: capabilities
          }

          send(listener_pid, {:configure, self(), listener})
          {:ok, listener}

        {^ref, {:error, _reason} = error} ->
          error
      end
    end
  end

  @impl true
  def connect(_host, port, opts, timeout) do
    with {:ok, network} <- fetch_network(opts),
         {:ok, requested_capabilities} <- profile_capabilities(option(opts, :profile, :draft_14)),
         {:ok, listener} <- lookup_listener(network, port, timeout),
         :ok <- compatible_capabilities(listener.capabilities, requested_capabilities) do
      client = start_connection(requested_capabilities, self())
      server = start_connection(listener.capabilities, nil)
      pair_connections(client, server)

      ref = make_ref()
      send(listener.pid, {:new_connection, self(), ref, server})

      receive do
        {^ref, :ok} ->
          send(
            self(),
            {:moqx_transport,
             {:connection_event, client, :connected, %{alpn: requested_capabilities.alpn}}}
          )

          {:ok, client}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  @impl true
  def local_address(%Listener{port: port}), do: {:ok, {{127, 0, 0, 1}, port}}
  def local_address(%Connection{}), do: {:error, :unsupported}

  @impl true
  def accept(%Listener{} = listener, _opts, timeout) do
    ref = make_ref()
    send(listener.pid, {:accept, self(), ref})

    receive do
      {^ref, {:ok, connection}} ->
        set_connection_owner(connection, self())
        capabilities = capabilities(connection)

        send(
          self(),
          {:moqx_transport,
           {:connection_event, connection, :connected, %{alpn: capabilities.alpn}}}
        )

        {:ok, connection}
    after
      timeout ->
        send(listener.pid, {:cancel_accept, ref})
        {:error, :timeout}
    end
  end

  @impl true
  def handshake(%Connection{} = connection, timeout) do
    ref = make_ref()
    send(connection.pid, {:handshake, self(), ref})

    receive do
      {^ref, :ok} -> {:ok, connection}
    after
      timeout -> {:error, :timeout}
    end
  end

  @impl true
  def capabilities(%Connection{} = connection) do
    ref = make_ref()
    send(connection.pid, {:capabilities, self(), ref})

    receive do
      {^ref, capabilities} -> capabilities
    end
  end

  @impl true
  def normalize_message({:moqx_transport, event}), do: event
  def normalize_message(_message), do: :unknown

  @impl true
  def open_stream(%Connection{} = connection, opts) do
    direction = option(opts, :direction, :bidirectional)
    ref = make_ref()
    send(connection.pid, {:open_stream, self(), ref, direction})

    receive do
      {^ref, result} -> result
    end
  end

  @impl true
  def accept_stream(%Connection{} = connection, _opts, timeout) do
    ref = make_ref()
    send(connection.pid, {:accept_stream, self(), ref})

    receive do
      {^ref, result} -> result
    after
      timeout ->
        send(connection.pid, {:cancel_accept_stream, ref})
        {:error, :timeout}
    end
  end

  @impl true
  def send_stream(%Stream{} = stream, data, opts) do
    ref = make_ref()

    send(
      stream.pid,
      {:send_data, self(), ref, IO.iodata_to_binary(data), option(opts, :finish, false) == true}
    )

    receive do
      {^ref, result} -> result
    end
  end

  @impl true
  def recv_stream(%Stream{} = stream, byte_count) do
    ref = make_ref()
    send(stream.pid, {:recv_data, self(), ref, byte_count})

    receive do
      {^ref, result} -> result
    end
  end

  @impl true
  def send_datagram(%Connection{} = connection, data) when is_binary(data) do
    ref = make_ref()
    send(connection.pid, {:send_datagram, self(), ref, data})

    receive do
      {^ref, result} -> result
    end
  end

  @impl true
  def finish_sending(%Stream{} = stream) do
    stream_command(stream, :finish_sending, [])
  end

  @impl true
  def abort_sending(%Stream{} = stream, error_code)
      when is_integer(error_code) and error_code >= 0 do
    stream_command(stream, :abort_sending, [error_code])
  end

  @impl true
  def abort_receiving(%Stream{} = stream, error_code)
      when is_integer(error_code) and error_code >= 0 do
    stream_command(stream, :abort_receiving, [error_code])
  end

  defp stream_command(%Stream{} = stream, command, args) do
    ref = make_ref()
    send(stream.pid, {command, self(), ref, args})

    receive do
      {^ref, result} -> result
    end
  end

  @impl true
  def close_connection(%Connection{} = connection, reason)
      when is_integer(reason) and reason >= 0 do
    ref = make_ref()
    send(connection.pid, {:close_connection, self(), ref, reason})

    receive do
      {^ref, result} -> result
    end
  end

  @impl true
  def set_active(%Stream{} = stream, active) do
    ref = make_ref()
    send(stream.pid, {:set_active, self(), ref, active})

    receive do
      {^ref, result} -> result
    end
  end

  @impl true
  def controlling_process(%Listener{} = listener, pid) when is_pid(pid) do
    ref = make_ref()
    send(listener.pid, {:set_owner, self(), ref, pid})

    receive do
      {^ref, result} -> result
    end
  end

  def controlling_process(%Connection{} = connection, pid) when is_pid(pid) do
    ref = make_ref()
    send(connection.pid, {:set_owner, self(), ref, pid})

    receive do
      {^ref, result} -> result
    end
  end

  def controlling_process(%Stream{} = stream, pid) when is_pid(pid) do
    ref = make_ref()
    send(stream.pid, {:set_owner, self(), ref, pid})

    receive do
      {^ref, result} -> result
    end
  end

  def start_network do
    {:ok, %Network{pid: spawn(fn -> network_loop(%{}, 49_152) end)}}
  end

  def port(%Listener{port: port}), do: port

  defp start_connection(capabilities, owner) do
    state = %{
      capabilities: capabilities,
      handshaken?: false,
      owner: owner,
      peer: nil,
      pending_streams: :queue.new(),
      stream_acceptors: :queue.new()
    }

    %Connection{pid: spawn(fn -> connection_loop(state) end)}
  end

  defp pair_connections(%Connection{} = left, %Connection{} = right) do
    send(left.pid, {:set_peer, right})
    send(right.pid, {:set_peer, left})
  end

  defp set_connection_owner(%Connection{} = connection, owner) do
    send(connection.pid, {:set_owner, owner})
  end

  defp network_loop(listeners, next_port) do
    receive do
      {:listen, caller, ref, requested_port, listener_pid, capabilities} ->
        port = if requested_port == 0, do: next_port, else: requested_port

        if Map.has_key?(listeners, port) do
          send(caller, {ref, {:error, :eaddrinuse}})
          network_loop(listeners, next_port)
        else
          listener = %Listener{pid: listener_pid, port: port, capabilities: capabilities}
          send(caller, {ref, {:ok, port}})
          network_loop(Map.put(listeners, port, listener), max(next_port + 1, port + 1))
        end

      {:lookup, caller, ref, port} ->
        case Map.fetch(listeners, port) do
          {:ok, listener} -> send(caller, {ref, {:ok, listener}})
          :error -> send(caller, {ref, {:error, :econnrefused}})
        end

        network_loop(listeners, next_port)
    end
  end

  defp listener_loop(pending, acceptors, owner, listener) do
    receive do
      {:configure, new_owner, new_listener} ->
        listener_loop(pending, acceptors, new_owner, new_listener)

      {:set_owner, caller, ref, new_owner} ->
        send(caller, {ref, :ok})
        listener_loop(pending, acceptors, new_owner, listener)

      {:new_connection, caller, ref, connection} ->
        if owner && listener do
          send(owner, {:moqx_transport, {:listener_event, listener, :new_conn, %{}}})
        end

        case :queue.out(acceptors) do
          {{:value, {accept_ref, acceptor}}, remaining_acceptors} ->
            send(acceptor, {accept_ref, {:ok, connection}})
            send(caller, {ref, :ok})
            listener_loop(pending, remaining_acceptors, owner, listener)

          {:empty, _acceptors} ->
            send(caller, {ref, :ok})
            listener_loop(:queue.in(connection, pending), acceptors, owner, listener)
        end

      {:accept, caller, ref} ->
        case :queue.out(pending) do
          {{:value, connection}, remaining_pending} ->
            send(caller, {ref, {:ok, connection}})
            listener_loop(remaining_pending, acceptors, owner, listener)

          {:empty, _pending} ->
            listener_loop(pending, :queue.in({ref, caller}, acceptors), owner, listener)
        end

      {:cancel_accept, ref} ->
        listener_loop(pending, reject_acceptor(acceptors, ref), owner, listener)
    end
  end

  defp reject_acceptor(acceptors, ref) do
    acceptors
    |> :queue.to_list()
    |> Enum.reject(fn {accept_ref, _acceptor} -> accept_ref == ref end)
    |> :queue.from_list()
  end

  defp connection_loop(state) do
    receive do
      {:set_peer, peer} ->
        connection_loop(%{state | peer: peer})

      {:set_owner, owner} ->
        connection_loop(%{state | owner: owner})

      {:set_owner, caller, ref, owner} ->
        send(caller, {ref, :ok})
        connection_loop(%{state | owner: owner})

      {:handshake, caller, ref} ->
        send(caller, {ref, :ok})
        connection_loop(%{state | handshaken?: true})

      {:capabilities, caller, ref} ->
        send(caller, {ref, state.capabilities})
        connection_loop(state)

      {:send_datagram, caller, ref, data} ->
        if state.capabilities.datagrams == true do
          send(state.peer.pid, {:incoming_datagram, caller, ref, data})
        else
          send(caller, {ref, {:error, :datagrams_unavailable}})
        end

        connection_loop(state)

      {:close_connection, caller, ref, error_code} ->
        send(state.peer.pid, {:peer_closed_connection, error_code})
        send(caller, {ref, :ok})
        connection_loop(state)

      {:peer_closed_connection, error_code} ->
        if state.owner do
          send(
            state.owner,
            {:moqx_transport,
             {:connection_event, %Connection{pid: self()}, :closed,
              %{error_code: error_code, initiator: :peer}}}
          )
        end

        connection_loop(state)

      {:incoming_datagram, sender, ref, data} ->
        if state.capabilities.datagrams == true do
          if state.owner do
            send(state.owner, {:moqx_transport, {:datagram, %Connection{pid: self()}, data, %{}}})
          end

          send(sender, {ref, :ok})
        else
          send(sender, {ref, {:error, :datagrams_unavailable}})
        end

        connection_loop(state)

      {:open_stream, caller, ref, direction} ->
        local_stream = start_stream(caller)
        remote_stream = start_stream(nil)
        pair_streams(local_stream, remote_stream)

        send(state.peer.pid, {:incoming_stream, remote_stream, direction})
        send(caller, {ref, {:ok, local_stream}})

        send(
          caller,
          {:moqx_transport,
           {:stream_event, local_stream, :start_completed,
            %{direction: direction, initiator: :local}}}
        )

        connection_loop(state)

      {:incoming_stream, stream, direction} ->
        case :queue.out(state.stream_acceptors) do
          {{:value, {accept_ref, acceptor}}, remaining_acceptors} ->
            set_stream_owner(stream, acceptor)
            send(acceptor, {accept_ref, {:ok, stream}})

            send(
              acceptor,
              {:moqx_transport,
               {:stream_event, stream, :new_stream, %{direction: direction, initiator: :peer}}}
            )

            connection_loop(%{state | stream_acceptors: remaining_acceptors})

          {:empty, _acceptors} ->
            pending = :queue.in({stream, direction}, state.pending_streams)
            connection_loop(%{state | pending_streams: pending})
        end

      {:accept_stream, caller, ref} ->
        case :queue.out(state.pending_streams) do
          {{:value, {stream, direction}}, remaining_pending} ->
            set_stream_owner(stream, caller)
            send(caller, {ref, {:ok, stream}})

            send(
              caller,
              {:moqx_transport,
               {:stream_event, stream, :new_stream, %{direction: direction, initiator: :peer}}}
            )

            connection_loop(%{state | pending_streams: remaining_pending})

          {:empty, _pending} ->
            acceptors = :queue.in({ref, caller}, state.stream_acceptors)
            connection_loop(%{state | stream_acceptors: acceptors})
        end

      {:cancel_accept_stream, ref} ->
        connection_loop(%{state | stream_acceptors: reject_acceptor(state.stream_acceptors, ref)})
    end
  end

  defp start_stream(owner) do
    state = %{
      owner: owner,
      peer: nil,
      buffer: <<>>,
      recvs: :queue.new(),
      active: false,
      send_finished?: false
    }

    %Stream{pid: spawn(fn -> stream_loop(state) end)}
  end

  defp pair_streams(%Stream{} = left, %Stream{} = right) do
    send(left.pid, {:set_peer, right})
    send(right.pid, {:set_peer, left})
  end

  defp set_stream_owner(%Stream{} = stream, owner) do
    send(stream.pid, {:set_owner, owner})
  end

  defp stream_loop(state) do
    receive do
      {:set_peer, peer} ->
        stream_loop(%{state | peer: peer})

      {:set_owner, owner} ->
        stream_loop(%{state | owner: owner})

      {:set_owner, caller, ref, owner} ->
        send(caller, {ref, :ok})
        stream_loop(%{state | owner: owner})

      {:send_data, caller, ref, _data, _finish?} when state.send_finished? ->
        send(caller, {ref, {:error, :send_side_finished}})
        stream_loop(state)

      {:send_data, caller, ref, data, finish?} ->
        send(state.peer.pid, {:incoming_data, data})

        if finish? do
          send(state.peer.pid, {:peer_finished_sending})
        end

        send(caller, {ref, :ok})

        send(
          caller,
          {:moqx_transport, {:stream_event, %Stream{pid: self()}, :send_complete, false}}
        )

        stream_loop(%{state | send_finished?: finish?})

      {:incoming_data, data} ->
        if state.active && state.owner do
          send(state.owner, {:moqx_transport, {:stream_data, %Stream{pid: self()}, data, %{}}})
          stream_loop(state)
        else
          stream_loop(deliver_passive_data(%{state | buffer: state.buffer <> data}))
        end

      {:finish_sending, caller, ref, []} when state.send_finished? ->
        send(caller, {ref, {:error, :send_side_finished}})
        stream_loop(state)

      {:finish_sending, caller, ref, []} ->
        send(state.peer.pid, {:peer_finished_sending})
        send(caller, {ref, :ok})
        stream_loop(%{state | send_finished?: true})

      {:abort_sending, caller, ref, [error_code]} ->
        send(state.peer.pid, {:peer_aborted_sending, error_code})
        send(caller, {ref, :ok})
        stream_loop(state)

      {:abort_receiving, caller, ref, [error_code]} ->
        send(state.peer.pid, {:peer_aborted_receiving, error_code})
        send(caller, {ref, :ok})
        stream_loop(state)

      {:peer_finished_sending} ->
        send_stream_event(state, :peer_finished_sending, %{})
        stream_loop(state)

      {:peer_aborted_sending, error_code} ->
        send_stream_event(state, :peer_aborted_sending, %{error_code: error_code})
        stream_loop(state)

      {:peer_aborted_receiving, error_code} ->
        send_stream_event(state, :peer_aborted_receiving, %{error_code: error_code})
        stream_loop(state)

      {:set_active, caller, ref, active} ->
        send(caller, {ref, :ok})
        stream_loop(%{state | active: active})

      {:recv_data, caller, ref, byte_count} ->
        case take_bytes(state.buffer, byte_count) do
          {:ok, data, remaining} ->
            send(caller, {ref, {:ok, data}})
            stream_loop(%{state | buffer: remaining})

          :not_enough_data ->
            stream_loop(%{state | recvs: :queue.in({caller, ref, byte_count}, state.recvs)})
        end

      {:stop, _reason} ->
        :ok
    end
  end

  defp send_stream_event(state, event, metadata) do
    if state.owner do
      send(state.owner, {:moqx_transport, {:stream_event, %Stream{pid: self()}, event, metadata}})
    end
  end

  defp deliver_passive_data(state) do
    case :queue.out(state.recvs) do
      {{:value, {caller, ref, byte_count}}, remaining_recvs} ->
        case take_bytes(state.buffer, byte_count) do
          {:ok, data, remaining_buffer} ->
            send(caller, {ref, {:ok, data}})
            deliver_passive_data(%{state | buffer: remaining_buffer, recvs: remaining_recvs})

          :not_enough_data ->
            state
        end

      {:empty, _recvs} ->
        state
    end
  end

  defp take_bytes(buffer, byte_count) when byte_size(buffer) >= byte_count do
    <<data::binary-size(^byte_count), remaining::binary>> = buffer
    {:ok, data, remaining}
  end

  defp take_bytes(_buffer, _byte_count), do: :not_enough_data

  defp lookup_listener(network, port, timeout) do
    ref = make_ref()
    send(network.pid, {:lookup, self(), ref, port})

    receive do
      {^ref, {:ok, %Listener{} = listener}} -> {:ok, listener}
      {^ref, {:error, _reason} = error} -> error
    after
      timeout -> {:error, :timeout}
    end
  end

  defp compatible_capabilities(%Capabilities{alpn: alpn}, %Capabilities{alpn: alpn}), do: :ok
  defp compatible_capabilities(_listener, _requested), do: {:error, :alpn_mismatch}

  defp fetch_network(opts) do
    case option(opts, :network, nil) do
      %Network{} = network -> {:ok, network}
      nil -> {:error, :network_required}
    end
  end

  defp profile_capabilities(%Capabilities{} = capabilities), do: {:ok, capabilities}

  defp profile_capabilities(profile) do
    with {:ok, profile} <- Profile.fetch(profile) do
      {:ok, profile.capabilities}
    end
  end

  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
end
