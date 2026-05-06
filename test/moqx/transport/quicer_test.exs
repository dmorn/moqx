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
               {:datagram, :connection, "payload", :flags}
    end

    test "returns unknown for unrecognized backend messages" do
      assert Quicer.normalize_message({:other_backend, :message}) == :unknown
    end
  end
end
