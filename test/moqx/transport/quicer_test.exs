defmodule MOQX.Transport.QuicerTest do
  use ExUnit.Case, async: true

  alias MOQX.Transport.Quicer

  describe "datagram_send_flags/1" do
    test "normalizes named DATAGRAM send flags to MsQuic bitmask" do
      assert Quicer.datagram_send_flags(datagram_send_flags: [:dgram_priority]) == 0x0008

      assert Quicer.datagram_send_flags(datagram_send_flags: [:dgram_priority, :priority_work]) ==
               0x0048
    end

    test "rejects unknown DATAGRAM send flags" do
      assert_raise ArgumentError, fn ->
        Quicer.datagram_send_flags(datagram_send_flags: [:unknown])
      end
    end
  end

  describe "stream_info_from_id/3" do
    test "derives exact local and peer role metadata from QUIC stream IDs" do
      assert Quicer.stream_info_from_id(0, :client, :local) ==
               %MOQX.Transport.Conn.Stream.Info{
                 stream_id: 0,
                 direction: :bidirectional,
                 initiator: :local,
                 initiator_role: :client,
                 local_role: :client,
                 send_side?: true,
                 receive_side?: true
               }

      assert Quicer.stream_info_from_id(2, :server, :peer) ==
               %MOQX.Transport.Conn.Stream.Info{
                 stream_id: 2,
                 direction: :unidirectional,
                 initiator: :peer,
                 initiator_role: :client,
                 local_role: :server,
                 send_side?: false,
                 receive_side?: true
               }
    end
  end

  describe "normalize_message/1" do
    test "normalizes stream data messages" do
      props = %{absolute_offset: 0, len: 7, flags: 0}

      assert Quicer.normalize_message({:quic, "payload", :stream, props}) ==
               {:stream_data, :stream, "payload", props}
    end

    test "normalizes datagram messages" do
      assert Quicer.normalize_message({:quic, "payload", :connection, :flags}) ==
               {:datagram, :connection, "payload", %{flags: :flags}}
    end

    test "normalizes datagram send-state messages as connection events" do
      assert Quicer.normalize_message(
               {:quic, :dgram_send_state, :connection, %{state: :dgram_send_acknowledged}}
             ) ==
               {:connection_event, :connection, :dgram_send_state,
                %{state: :dgram_send_acknowledged}}
    end

    test "normalizes quicer shutdown stream events into MOQX event vocabulary" do
      assert Quicer.normalize_message({:quic, :peer_send_shutdown, :stream, :undefined}) ==
               {:stream_event, :stream, :peer_finished_sending, %{}}

      assert Quicer.normalize_message({:quic, :peer_send_aborted, :stream, 42}) ==
               {:stream_event, :stream, :peer_aborted_sending, %{error_code: 42}}

      assert Quicer.normalize_message({:quic, :peer_receive_aborted, :stream, 7}) ==
               {:stream_event, :stream, :peer_aborted_receiving, %{error_code: 7}}

      assert Quicer.normalize_message({:quic, :send_shutdown_complete, :stream, true}) ==
               {:stream_event, :stream, :sending_finished, %{}}

      assert Quicer.normalize_message({:quic, :send_shutdown_complete, :stream, false}) ==
               {:stream_event, :stream, :sending_aborted, %{}}
    end

    test "normalizes quicer connection shutdown into canonical close event" do
      assert Quicer.normalize_message({:quic, :shutdown, :connection, 3}) ==
               {:connection_event, :connection, :closed, %{error_code: 3, initiator: :peer}}
    end

    test "returns unknown for unrecognized backend messages" do
      assert Quicer.normalize_message({:other_backend, :message}) == :unknown
    end
  end
end
