defmodule MOQX.Transport.SupportTest do
  use ExUnit.Case, async: true

  alias MOQX.Transport.Support

  test "establishes a deterministic client/server connection lifecycle" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :draft14)

    {:ok, client} =
      Support.connect(
        "localhost",
        Support.port(listener),
        [network: network, profile: :draft14],
        100
      )

    {:ok, server} = Support.accept(listener, [], 100)

    assert {:ok, ^client} = Support.handshake(client, 100)
    assert {:ok, ^server} = Support.handshake(server, 100)
  end

  test "emits normalized connection events for established peers" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :draft14)

    {:ok, client} =
      Support.connect(
        "localhost",
        Support.port(listener),
        [network: network, profile: :draft14],
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

  test "reports draft-14-like negotiated capabilities" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :draft14)

    {:ok, client} =
      Support.connect(
        "localhost",
        Support.port(listener),
        [network: network, profile: :draft14],
        100
      )

    assert Support.capabilities(client) == %MOQX.Transport.Capabilities{
             alpn: "moq-00",
             datagrams: true,
             max_datagram_size: 1200,
             stream_directions: [:bidirectional, :unidirectional],
             stream_priority: :supported,
             transport_stats: :unsupported
           }
  end

  test "reports MOQ Lite-like negotiated capabilities" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :moq_lite)

    {:ok, client} =
      Support.connect(
        "localhost",
        Support.port(listener),
        [network: network, profile: :moq_lite],
        100
      )

    assert Support.capabilities(client) == %MOQX.Transport.Capabilities{
             alpn: "moq-lite-04",
             datagrams: false,
             max_datagram_size: :unsupported,
             stream_directions: [:bidirectional, :unidirectional],
             stream_priority: :supported,
             transport_stats: :unsupported
           }
  end

  test "accept times out deterministically when no peer connects" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :draft14)

    assert Support.accept(listener, [], 0) == {:error, :timeout}
  end

  test "connect rejects incompatible ALPN profiles" do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: :draft14)

    assert Support.connect(
             "localhost",
             Support.port(listener),
             [network: network, profile: :moq_lite],
             100
           ) ==
             {:error, :alpn_mismatch}
  end
end
