defmodule MOQX.Protocol.ScaffoldTest do
  use ExUnit.Case, async: true

  alias MOQX.Operation
  alias MOQX.Protocol
  alias MOQX.Protocol.{Capabilities, Resolver, Transition, TransportSpec}

  defmodule CustomProtocol do
    @behaviour Protocol

    @impl true
    def id, do: :custom

    @impl true
    def transport_spec(_endpoint, _options), do: {:ok, %TransportSpec{alpn: "custom"}}

    @impl true
    def init(_endpoint, _options), do: {:ok, %{}}

    @impl true
    def handle_operation(state, _operation), do: Transition.ok(state)

    @impl true
    def handle_transport(state, _event), do: Transition.ok(state)

    @impl true
    def capabilities(_state), do: %Capabilities{}
  end

  test "resolves every built-in protocol explicitly" do
    assert Resolver.ids() == [:cloudflare_draft_14, :draft_16]

    assert {:ok, MOQX.Protocol.CloudflareDraft14} =
             Resolver.fetch(:cloudflare_draft_14)

    assert {:ok, MOQX.Protocol.Draft16} = Resolver.fetch(:draft_16)

    assert {:error, :unknown_protocol} = Resolver.fetch(:moq_lite_04)
    assert {:error, :unknown_protocol} = Resolver.fetch(:moqtail_draft_14)
  end

  test "accepts complete custom implementations without endpoint inference" do
    assert Protocol.implementation?(CustomProtocol)
    assert {:ok, CustomProtocol} = Resolver.fetch(CustomProtocol)
    assert {:error, :unknown_protocol} = Resolver.fetch(:not_a_protocol)
  end

  test "transition retains state, public events, and transport actions" do
    assert {:ok, %Transition{state: :active, events: [:ready], actions: [:open_control]}} =
             Transition.ok(:active, events: [:ready], actions: [:open_control])

    assert {:error, :unsupported,
            %Transition{state: :active, events: [], actions: [:close_connection]}} =
             Transition.error(:active, :unsupported, actions: [:close_connection])
  end

  test "public subscribe intent contains a protocol-neutral track address" do
    track = %MOQX.TrackRef{namespace: ["bbb"], track: ".catalog"}

    assert %Operation.Subscribe{track: ^track, options: [priority: 0]} =
             %Operation.Subscribe{track: track, options: [priority: 0]}
  end
end
