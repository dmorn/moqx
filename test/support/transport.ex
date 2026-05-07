defmodule MOQX.Transport.Support do
  @moduledoc false

  @behaviour MOQX.Transport

  alias MOQX.Transport.Capabilities

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

  @draft14 %Capabilities{
    alpn: "moq-00",
    datagrams: true,
    max_datagram_size: 1200,
    stream_directions: [:bidirectional, :unidirectional],
    stream_priority: :supported,
    transport_stats: :unsupported
  }

  @moq_lite %Capabilities{
    alpn: "moq-lite-04",
    datagrams: false,
    max_datagram_size: :unsupported,
    stream_directions: [:bidirectional, :unidirectional],
    stream_priority: :supported,
    transport_stats: :unsupported
  }

  @impl true
  def listen(port, opts) do
    with {:ok, network} <- fetch_network(opts),
         {:ok, capabilities} <- profile_capabilities(option(opts, :profile, :draft14)) do
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
         {:ok, requested_capabilities} <- profile_capabilities(option(opts, :profile, :draft14)),
         {:ok, listener} <- lookup_listener(network, port, timeout),
         :ok <- compatible_capabilities(listener.capabilities, requested_capabilities) do
      client = start_connection(requested_capabilities)
      server = start_connection(listener.capabilities)

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
  def accept(%Listener{} = listener, _opts, timeout) do
    ref = make_ref()
    send(listener.pid, {:accept, self(), ref})

    receive do
      {^ref, {:ok, connection}} ->
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
  def open_stream(_connection, _opts), do: {:error, :not_implemented}

  @impl true
  def accept_stream(_connection, _opts, _timeout), do: {:error, :not_implemented}

  @impl true
  def send_stream(_stream, _data, _opts), do: {:error, :not_implemented}

  @impl true
  def recv_stream(_stream, _byte_count), do: {:error, :not_implemented}

  @impl true
  def send_datagram(_connection, _data), do: {:error, :not_implemented}

  @impl true
  def close_stream(_stream, _reason), do: {:error, :not_implemented}

  @impl true
  def close_connection(_connection, _reason), do: {:error, :not_implemented}

  @impl true
  def set_active(_stream, _active), do: {:error, :not_implemented}

  @impl true
  def controlling_process(_handle, _pid), do: {:error, :not_implemented}

  def start_network do
    {:ok, %Network{pid: spawn(fn -> network_loop(%{}, 49_152) end)}}
  end

  def port(%Listener{port: port}), do: port

  defp start_connection(capabilities) do
    %Connection{pid: spawn(fn -> connection_loop(capabilities, false) end)}
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

  defp connection_loop(capabilities, handshaken?) do
    receive do
      {:handshake, caller, ref} ->
        send(caller, {ref, :ok})
        connection_loop(capabilities, true)

      {:capabilities, caller, ref} ->
        send(caller, {ref, capabilities})
        connection_loop(capabilities, handshaken?)
    end
  end

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

  defp profile_capabilities(:draft14), do: {:ok, @draft14}
  defp profile_capabilities(:moq_lite), do: {:ok, @moq_lite}
  defp profile_capabilities(%Capabilities{} = capabilities), do: {:ok, capabilities}
  defp profile_capabilities(_profile), do: {:error, :unknown_profile}

  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
end
