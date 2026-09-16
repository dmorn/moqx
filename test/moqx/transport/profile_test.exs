defmodule MOQX.Transport.ProfileTest do
  use ExUnit.Case, async: true

  alias MOQX.Transport.{Capabilities, Profile}

  describe "fetch/1" do
    test "returns the streams-only transport fixture" do
      assert {:ok, %Profile{} = profile} = Profile.fetch(:streams_only)

      assert profile.name == :streams_only
      assert profile.alpn == "moqx-streams"

      assert profile.capabilities == %Capabilities{
               alpn: "moqx-streams",
               datagrams: false,
               max_datagram_size: :unsupported,
               stream_directions: [:bidirectional, :unidirectional],
               stream_priority: :supported,
               transport_stats: :unsupported
             }

      assert profile.stream_expectations == %{
               bidirectional_streams: %{
                 direction: :bidirectional,
                 count: :many,
                 role: :application_defined
               },
               data_streams: %{direction: :unidirectional, role: :application_defined},
               datagrams: %{available: false, role: :none}
             }
    end

    test "returns the draft-18 transport fixture" do
      assert {:ok, %Profile{} = profile} = Profile.fetch(:draft_18)

      assert profile.name == :draft_18
      assert profile.alpn == "moqt-18"
      assert profile.capabilities.alpn == "moqt-18"
      assert profile.stream_expectations.control_streams.count == :one_each
    end

    test "returns the native QUIC MoQ Lite draft-05 fixture" do
      assert {:ok, %Profile{} = profile} = Profile.fetch(:moq_lite_05)

      assert profile.name == :moq_lite_05
      assert profile.alpn == "moq-lite-05"
      assert profile.capabilities.datagrams == false
      assert profile.stream_expectations.setup_stream.direction == :unidirectional
      assert profile.stream_expectations.application_streams.count == :many
    end

    test "lists canonical profile names" do
      assert Profile.names() == [:draft_18, :moq_lite_05, :streams_only]
    end

    test "rejects unknown profiles" do
      assert Profile.fetch(:unknown) == {:error, :unknown_profile}
    end
  end

  describe "helpers" do
    test "expose capabilities and ALPN from canonical names" do
      assert {:ok, "moqt-18"} = Profile.alpn(:draft_18)
      assert {:ok, %Capabilities{datagrams: false}} = Profile.capabilities(:streams_only)
    end
  end
end
