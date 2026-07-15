defmodule MOQX.Transport.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias MOQX.Transport.Capabilities

  describe "from_quicer/3" do
    test "normalizes successful quicer capability queries" do
      assert Capabilities.from_quicer({:ok, ~c"moq-00"}, {:ok, true}, {:ok, true}) ==
               %Capabilities{
                 alpn: "moq-00",
                 datagrams: true,
                 max_datagram_size: :unknown,
                 stream_directions: [:bidirectional, :unidirectional],
                 stream_priority: :supported,
                 transport_stats: :supported
               }
    end

    test "reports datagrams unavailable if either direction is disabled" do
      assert %Capabilities{datagrams: false} =
               Capabilities.from_quicer({:ok, "moqx-streams"}, {:ok, false}, {:ok, true})

      assert %Capabilities{datagrams: false} =
               Capabilities.from_quicer({:ok, "moqx-streams"}, {:ok, true}, {:ok, false})
    end

    test "reports unknown values when quicer cannot provide them" do
      assert Capabilities.from_quicer({:error, :not_found}, {:error, :not_found}, {:ok, true}) ==
               %Capabilities{
                 alpn: :unknown,
                 datagrams: :unknown,
                 max_datagram_size: :unknown,
                 stream_directions: [:bidirectional, :unidirectional],
                 stream_priority: :supported,
                 transport_stats: :supported
               }
    end
  end
end
