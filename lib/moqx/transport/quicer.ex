defmodule MOQX.Transport.Quicer do
  @moduledoc """
  `MOQX.Transport` implementation backed by `quicer`.

  This module is intentionally thin. It normalizes `quicer`'s handle-oriented
  API and owner-process messages without embedding any MOQT protocol logic.
  """

  @behaviour MOQX.Transport

  @impl true
  def listen(port, opts) do
    :quicer.listen(port, opts)
  end

  @impl true
  def accept(listener, opts, timeout \\ :infinity) do
    :quicer.accept(listener, opts, timeout)
  end

  @impl true
  def handshake(connection, timeout \\ 5_000) do
    :quicer.handshake(connection, timeout)
  end

  @impl true
  def connect(host, port, opts, timeout \\ 5_000) do
    :quicer.connect(host, port, opts, timeout)
  end

  @impl true
  def open_stream(connection, opts \\ []) do
    :quicer.start_stream(connection, opts)
  end

  @impl true
  def accept_stream(connection, opts \\ [], timeout \\ :infinity) do
    :quicer.accept_stream(connection, opts, timeout)
  end

  @impl true
  def send_stream(stream, data, opts \\ []) do
    case :quicer.send(stream, data, option(opts, :flags, 0)) do
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
    case :quicer.send_dgram(connection, data) do
      {:ok, _bytes} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def close_stream(stream, _reason \\ :normal) do
    :quicer.close_stream(stream)
  end

  @impl true
  def close_connection(connection, _reason \\ :normal) do
    :quicer.close_connection(connection)
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
  def normalize_message({:quic, data, stream, %{absolute_offset: _, len: _, flags: _} = props})
      when is_binary(data) do
    {:stream_data, stream, data, props}
  end

  def normalize_message({:quic, data, connection, flags}) when is_binary(data) do
    {:datagram, connection, data, flags}
  end

  def normalize_message({:quic, :new_conn, connection, props}) do
    {:listener_event, connection, :new_conn, props}
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
    {:stream_event, stream, event, props}
  end

  def normalize_message({:quic, :listener_stopped, listener, props}) do
    {:listener_event, listener, :listener_stopped, props}
  end

  def normalize_message({:quic, :listener_stopped, listener}) do
    {:listener_event, listener, :listener_stopped, nil}
  end

  def normalize_message(_message), do: :unknown

  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
end
