defmodule MOQX.MOQLite04.ClientTest do
  use ExUnit.Case, async: true

  alias MOQX.MOQLite04
  alias MOQX.MOQLite04.{Client, Session}
  alias MOQX.Transport
  alias MOQX.Transport.Support

  test "connects with a URI string over the support transport" do
    %{network: network, listener: listener, listener_ctx: listener_ctx, port: port} =
      start_support_listener()

    uri = "moq-lite://localhost:#{port}/live?track=video"

    assert {:ok, %Client{} = client} =
             MOQLite04.connect(uri,
               transport: {Support, network: network, profile: :moq_lite_04},
               timeout: 100
             )

    assert %URI{
             scheme: "moq-lite",
             host: "localhost",
             port: ^port,
             path: "/live",
             query: "track=video"
           } = client.uri

    assert %Session{alpn: "moq-lite-04", streams: %{}} = client.session
    assert %MOQX.Transport.Context{} = client.context
    assert %MOQX.Transport.Connection{local_role: :client} = client.connection

    assert %MOQX.Transport.Capabilities{alpn: "moq-lite-04"} =
             Transport.capabilities(client.context, client.connection)

    assert client.context.backend.data.streams == %{}

    assert {:ok, server, listener_ctx} = Transport.accept(listener_ctx, listener, [], 100)
    assert {:ok, _server, _listener_ctx} = Transport.handshake(listener_ctx, server, 100)
  end

  test "connects with a parsed URI struct" do
    %{network: network, listener: listener, listener_ctx: listener_ctx, port: port} =
      start_support_listener()

    uri = URI.parse("moq-lite://localhost:#{port}/live")

    assert {:ok, %Client{uri: ^uri}} =
             MOQLite04.connect(uri,
               transport: {Support, network: network, profile: :moq_lite_04},
               timeout: 100
             )

    assert {:ok, server, listener_ctx} = Transport.accept(listener_ctx, listener, [], 100)
    assert {:ok, _server, _listener_ctx} = Transport.handshake(listener_ctx, server, 100)
  end

  test "rejects unsupported URI schemes" do
    assert MOQLite04.connect("https://localhost:4433/live") ==
             {:error, {:invalid_uri, {:unsupported_scheme, "https"}}}
  end

  test "rejects URI inputs without a host" do
    assert MOQLite04.connect("moq-lite:/live") == {:error, {:invalid_uri, :missing_host}}
  end

  test "rejects URI inputs without a port" do
    assert MOQLite04.connect("moq-lite://localhost/live") ==
             {:error, {:invalid_uri, :missing_port}}
  end

  test "rejects URI inputs with userinfo" do
    assert MOQLite04.connect("moq-lite://user@localhost:4433/live") ==
             {:error, {:invalid_uri, :userinfo_not_supported}}
  end

  test "rejects URI inputs with fragments" do
    assert MOQLite04.connect("moq-lite://localhost:4433/live#track") ==
             {:error, {:invalid_uri, :fragment_not_supported}}
  end

  test "requires explicit transport selection" do
    assert MOQLite04.connect("moq-lite://localhost:4433/live") == {:error, :missing_transport}
  end

  test "rejects invalid transport option shapes" do
    assert MOQLite04.connect("moq-lite://localhost:4433/live", transport: Support) ==
             {:error, {:invalid_transport, Support}}

    assert MOQLite04.connect("moq-lite://localhost:4433/live", transport: {Support, :bad_opts}) ==
             {:error, {:invalid_transport, {Support, :bad_opts}}}
  end

  test "rejects publisher or subscriber connection modes" do
    for mode <- [:publisher, :subscriber] do
      assert MOQLite04.connect("moq-lite://localhost:4433/live", mode: mode) ==
               {:error, {:unsupported_option, :mode}}
    end
  end

  defp start_support_listener do
    {:ok, network} = Support.start_network()
    {:ok, listener_ctx} = Transport.new(Support, network: network)
    {:ok, listener, listener_ctx} = Transport.listen(listener_ctx, 0, profile: :moq_lite_04)
    {:ok, {_ip, port}} = Transport.local_address(listener_ctx, listener)

    %{network: network, listener: listener, listener_ctx: listener_ctx, port: port}
  end
end
