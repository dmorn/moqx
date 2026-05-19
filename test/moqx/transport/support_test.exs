defmodule MOQX.Transport.SupportTest do
  use ExUnit.Case, async: true

  alias MOQX.Transport.{Profile, Support}

  test "establishes a deterministic client/server connection lifecycle" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :draft_14)

    {:ok, client} =
      Support.connect(
        "localhost",
        Support.port(listener),
        [network: network, profile: :draft_14],
        100
      )

    {:ok, server} = Support.accept(listener, [], 100)

    assert {:ok, ^client} = Support.handshake(client, 100)
    assert {:ok, ^server} = Support.handshake(server, 100)
  end

  test "emits normalized connection events for established peers" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :draft_14)

    {:ok, client} =
      Support.connect(
        "localhost",
        Support.port(listener),
        [network: network, profile: :draft_14],
        100
      )

    client_events = [
      receive_backend_event(Support, 0),
      receive_backend_event(Support, 0)
    ]

    assert {:listener_event, listener, :new_conn, %{}} in client_events
    assert {:connection_event, client, :connected, %{alpn: "moq-00"}} in client_events

    {:ok, server} = Support.accept(listener, [], 100)

    assert {:connection_event, ^server, :connected, %{alpn: "moq-00"}} =
             receive_backend_event(Support, 0)
  end

  defp receive_backend_event(transport, timeout) do
    receive do
      message -> transport.normalize_message(message)
    after
      timeout -> :timeout
    end
  end

  test "reports draft_14 negotiated capabilities" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :draft_14)

    {:ok, client} =
      Support.connect(
        "localhost",
        Support.port(listener),
        [network: network, profile: :draft_14],
        100
      )

    assert Support.capabilities(client) == Profile.capabilities!(:draft_14)
  end

  test "accepts first-class profile fixtures" do
    profile = Profile.fetch!(:draft_14)
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: profile)

    {:ok, client} =
      Support.connect(
        "localhost",
        Support.port(listener),
        [network: network, profile: profile],
        100
      )

    assert Support.capabilities(client) == profile.capabilities
  end

  test "reports moq_lite_04 negotiated capabilities" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :moq_lite_04)

    {:ok, client} =
      Support.connect(
        "localhost",
        Support.port(listener),
        [network: network, profile: :moq_lite_04],
        100
      )

    assert Support.capabilities(client) == Profile.capabilities!(:moq_lite_04)
  end

  test "accept times out deterministically when no peer connects" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :draft_14)

    assert Support.accept(listener, [], 0) == {:error, :timeout}
  end

  test "connect rejects incompatible ALPN profiles" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :draft_14)

    assert Support.connect(
             "localhost",
             Support.port(listener),
             [network: network, profile: :moq_lite_04],
             100
           ) ==
             {:error, :alpn_mismatch}
  end
end
