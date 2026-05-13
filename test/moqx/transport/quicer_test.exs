defmodule MOQX.Transport.QuicerTest do
  use ExUnit.Case, async: true

  alias MOQX.Transport.Quicer

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
