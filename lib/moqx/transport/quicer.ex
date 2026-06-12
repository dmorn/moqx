defmodule MOQX.Transport.Quicer do
  @moduledoc """
  `MOQX.Transport` implementation backed by `quicer`.

  This module is intentionally thin. It normalizes `quicer`'s handle-oriented
  API and owner-process messages without embedding any MOQT protocol logic.
  """

  @behaviour MOQX.Transport

  import Bitwise, only: [&&&: 2, |||: 2]

  alias MOQX.Transport.Capabilities
  alias MOQX.Transport.Quicer.Options

  @quic_send_flag_fin 0x0004
  @quic_send_flag_dgram_priority 0x0008
  @quic_send_flag_priority_work 0x0040
  @quic_send_flag_cancel_on_blocked 0x0080
  @quicer_send_flag_sync 0x1000
  @datagram_send_flags %{
    dgram_priority: @quic_send_flag_dgram_priority,
    priority_work: @quic_send_flag_priority_work,
    cancel_on_blocked: @quic_send_flag_cancel_on_blocked
  }

  @impl true
  def listen(port, opts) do
    port
    |> Options.normalize_text()
    |> :quicer.listen(Options.normalize_opts(opts))
    |> normalize_result()
  end

  @impl true
  def accept(listener, opts, timeout \\ :infinity) do
    :quicer.accept(listener, Options.normalize_opts(opts), timeout)
  end

  @impl true
  def handshake(connection, timeout \\ 5_000) do
    :quicer.handshake(connection, timeout)
  end

  @impl true
  def connect(host, port, opts, timeout \\ 5_000) do
    :quicer.connect(Options.normalize_host(host), port, Options.normalize_opts(opts), timeout)
  end

  @doc """
  Returns the local address bound to a listener or connection.
  """
  @spec local_address(MOQX.Transport.listener() | MOQX.Transport.connection()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  @impl true
  def local_address(handle) do
    :quicer.getopt(handle, :local_address)
  end

  @doc """
  Returns exact stream info for a quicer stream handle.
  """
  @spec stream_info(MOQX.Transport.stream(), :client | :server, :local | :peer) ::
          {:ok, MOQX.Transport.Conn.Stream.Info.t()} | {:error, term()}
  @impl true
  def stream_info(stream, local_role, initiator) do
    case :quicer.get_stream_id(stream) do
      {:ok, stream_id} -> {:ok, stream_info_from_id(stream_id, local_role, initiator)}
      {:error, reason} -> {:error, reason}
      not_found -> {:error, not_found}
    end
  end

  @doc """
  Builds exact stream info from QUIC stream ID and local endpoint role.
  """
  @spec stream_info_from_id(non_neg_integer(), :client | :server, :local | :peer) ::
          MOQX.Transport.Conn.Stream.Info.t()
  def stream_info_from_id(stream_id, local_role, initiator) do
    initiator_role = initiator_role_from_stream_id(stream_id)
    direction = direction_from_stream_id(stream_id)

    %MOQX.Transport.Conn.Stream.Info{
      stream_id: stream_id,
      direction: direction,
      initiator: initiator,
      initiator_role: initiator_role,
      local_role: local_role,
      send_side?: send_side?(direction, initiator),
      receive_side?: receive_side?(direction, initiator)
    }
  end

  @doc """
  Closes a listener handle.
  """
  @spec close_listener(MOQX.Transport.listener(), timeout()) :: :ok | {:error, term()}
  @impl true
  def close_listener(listener, timeout \\ 0) do
    :quicer.close_listener(listener, timeout)
  end

  @impl true
  def open_stream(connection, opts \\ []) do
    with {:ok, stream} <- :quicer.start_stream(connection, Options.normalize_stream_opts(opts)),
         :ok <- maybe_set_stream_priority(stream, option(opts, :priority, nil)) do
      {:ok, stream}
    else
      error -> error
    end
  end

  @impl true
  def accept_stream(connection, opts \\ [], timeout \\ :infinity) do
    case :quicer.accept_stream(connection, Options.normalize_accept_stream_opts(opts), timeout) do
      {:ok, stream} ->
        send(
          self(),
          {:moqx_transport, {:stream_event, stream, :new_stream, peer_stream_metadata(stream)}}
        )

        {:ok, stream}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def send_stream(stream, data, opts \\ []) do
    case :quicer.async_send(stream, data, send_flags(opts)) do
      {:ok, _bytes} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def recv_stream(stream, byte_count) do
    :quicer.recv(stream, byte_count)
  end

  @impl true
  def send_datagram(connection, data) when is_binary(data) do
    send_datagram(connection, data, [])
  end

  @doc false
  @spec datagram_send_flags(keyword() | map()) :: non_neg_integer()
  def datagram_send_flags(opts) do
    opts
    |> option(:datagram_send_flags, [])
    |> normalize_datagram_send_flags()
  end

  @impl true
  def send_datagram(connection, data, opts) when is_binary(data) do
    case send_quicer_datagram(connection, data, datagram_send_flags(opts)) do
      {:ok, _bytes} -> :ok
      {:error, :dgram_send_error, :invalid_state} -> {:error, :datagrams_unavailable}
      {:error, _reason} = error -> error
      {:error, reason, details} -> {:error, {reason, details}}
    end
  end

  defp send_quicer_datagram(connection, data, send_flags) do
    :quicer.async_send_dgram(connection, data,
      report_send_state: false,
      send_flags: send_flags
    )
  end

  @impl true
  def finish_sending(stream) do
    :quicer.async_shutdown_stream(stream, 1, 0)
  end

  @impl true
  def abort_sending(stream, error_code) when is_integer(error_code) and error_code >= 0 do
    :quicer.async_shutdown_stream(stream, 2, error_code)
  end

  @impl true
  def abort_receiving(stream, error_code) when is_integer(error_code) and error_code >= 0 do
    :quicer.async_shutdown_stream(stream, 4, error_code)
  end

  @impl true
  def close_connection(connection, error_code) when is_integer(error_code) and error_code >= 0 do
    :quicer.async_close_connection(connection, 0, error_code)
  end

  @impl true
  def set_active(stream, active) do
    :quicer.setopt(stream, :active, active)
  end

  @impl true
  def controlling_process(handle, pid) when is_pid(pid) do
    :quicer.controlling_process(handle, pid)
  end

  @impl true
  def capabilities(connection) do
    Capabilities.from_quicer(
      :quicer.negotiated_protocol(connection),
      :quicer.getopt(connection, :datagram_send_enabled),
      :quicer.getopt(connection, :datagram_receive_enabled)
    )
  end

  @doc false
  def connection_statistics(connection) do
    case :quicer.getopt(connection, :statistics_v2) do
      {:ok, stats} when is_list(stats) ->
        {:ok, Map.new(stats, fn {key, value} -> {Atom.to_string(key), value} end)}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def normalize_message({:moqx_transport, event}), do: event

  def normalize_message({:quic, data, stream, %{absolute_offset: _, len: _, flags: _} = props})
      when is_binary(data) do
    {:stream_data, stream, data, props}
  end

  def normalize_message({:quic, data, connection, flags}) when is_binary(data) do
    {:datagram, connection, data, %{flags: flags}}
  end

  def normalize_message({:quic, :new_conn, connection, props}) do
    {:listener_event, connection, :new_conn, props}
  end

  def normalize_message({:quic, :shutdown, connection, error_code}) when is_integer(error_code) do
    {:connection_event, connection, :closed, %{error_code: error_code, initiator: :peer}}
  end

  def normalize_message({:quic, event, connection, props})
      when event in [
             :connected,
             :peer_cert_received,
             :transport_shutdown,
             :shutdown,
             :closed,
             :local_address_changed,
             :peer_address_changed,
             :streams_available,
             :peer_needs_streams,
             :dgram_state_changed,
             :dgram_send_state,
             :connection_resumed,
             :nst_received
           ] do
    {:connection_event, connection, event, props}
  end

  def normalize_message({:quic, event, stream, props})
      when event in [
             :new_stream,
             :start_completed,
             :send_complete,
             :peer_send_shutdown,
             :peer_send_aborted,
             :peer_receive_aborted,
             :send_shutdown_complete,
             :stream_closed,
             :peer_accepted,
             :continue,
             :passive
           ] do
    {event, metadata} = normalize_stream_event(event, props)
    {:stream_event, stream, event, metadata}
  end

  def normalize_message({:quic, :listener_stopped, listener, props}) do
    {:listener_event, listener, :listener_stopped, props}
  end

  def normalize_message({:quic, :listener_stopped, listener}) do
    {:listener_event, listener, :listener_stopped, nil}
  end

  def normalize_message(_message), do: :unknown

  defp normalize_stream_event(:peer_send_shutdown, _props), do: {:peer_finished_sending, %{}}

  defp normalize_stream_event(:peer_send_aborted, error_code),
    do: {:peer_aborted_sending, %{error_code: error_code}}

  defp normalize_stream_event(:peer_receive_aborted, error_code),
    do: {:peer_aborted_receiving, %{error_code: error_code}}

  defp normalize_stream_event(:send_shutdown_complete, true), do: {:sending_finished, %{}}
  defp normalize_stream_event(:send_shutdown_complete, false), do: {:sending_aborted, %{}}
  defp normalize_stream_event(:stream_closed, props), do: {:closed, props}

  defp normalize_stream_event(event, props),
    do: {event, normalize_stream_event_metadata(event, props)}

  defp peer_stream_metadata(stream) do
    case :quicer.get_stream_id(stream) do
      {:ok, stream_id} -> %{direction: direction_from_stream_id(stream_id), initiator: :peer}
      {:error, reason} -> %{direction: :unknown, initiator: :peer, metadata_error: reason}
    end
  end

  defp normalize_stream_event_metadata(:new_stream, %{flags: flags} = props) do
    props
    |> Map.put(:direction, direction_from_open_flags(flags))
    |> Map.put(:initiator, :peer)
  end

  defp normalize_stream_event_metadata(:start_completed, %{stream_id: stream_id} = props) do
    props
    |> Map.put(:direction, direction_from_stream_id(stream_id))
    |> Map.put(:initiator, :local)
  end

  defp normalize_stream_event_metadata(_event, props), do: props

  defp direction_from_open_flags(flags) when is_integer(flags) do
    if (flags &&& 1) == 1, do: :unidirectional, else: :bidirectional
  end

  defp direction_from_stream_id(stream_id) when is_integer(stream_id) do
    if (stream_id &&& 2) == 2, do: :unidirectional, else: :bidirectional
  end

  defp initiator_role_from_stream_id(stream_id) when is_integer(stream_id) do
    if (stream_id &&& 1) == 1, do: :server, else: :client
  end

  defp send_side?(:bidirectional, _initiator), do: true
  defp send_side?(:unidirectional, :local), do: true
  defp send_side?(:unidirectional, :peer), do: false

  defp receive_side?(:bidirectional, _initiator), do: true
  defp receive_side?(:unidirectional, :local), do: false
  defp receive_side?(:unidirectional, :peer), do: true

  defp normalize_result({:ok, _value} = ok), do: ok
  defp normalize_result({:error, _reason} = error), do: error
  defp normalize_result({:error, reason, details}), do: {:error, {reason, details}}

  defp send_flags(opts) do
    flags =
      opts
      |> option(:flags, 0)
      |> maybe_add_fin_flag(option(opts, :finish, false) == true)

    flags ||| @quicer_send_flag_sync
  end

  defp maybe_add_fin_flag(flags, true), do: flags ||| @quic_send_flag_fin
  defp maybe_add_fin_flag(flags, false), do: flags

  defp maybe_set_stream_priority(_stream, nil), do: :ok

  defp maybe_set_stream_priority(stream, priority) do
    case :quicer.setopt(stream, :priority, priority) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp normalize_datagram_send_flags(flags) when is_integer(flags) and flags >= 0, do: flags
  defp normalize_datagram_send_flags(nil), do: 0

  defp normalize_datagram_send_flags(flags) when is_list(flags) do
    Enum.reduce(flags, 0, fn flag, acc ->
      case Map.fetch(@datagram_send_flags, flag) do
        {:ok, value} -> acc ||| value
        :error -> raise ArgumentError, "unknown quicer DATAGRAM send flag: #{inspect(flag)}"
      end
    end)
  end

  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
end
