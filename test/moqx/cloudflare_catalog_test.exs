defmodule MOQX.CloudflareCatalogTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias MOQX.Transport
  alias MOQX.Transport.Support

  @tag :tmp_dir
  test "obtains Cloudflare's catalog and captures ordered H.264 CMAF", %{tmp_dir: tmp_dir} do
    {:ok, network} = Support.start_network()
    parent = self()
    catalog = catalog_payload()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :draft_14)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, control, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        client_setup = <<0x20, 0, 13, 1, 0xC0000000FF00000E::64, 1, 2, 0x4064::16>>

        assert {:ok, ^client_setup, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(client_setup))

        server_setup = <<0x21, 0, 9, 0xC0000000FF00000E::64, 0>>
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, server_setup)

        subscribe = <<0x03, 0, 20, 0, 1, 3, "bbb", 8, ".catalog", 127, 0, 1, 2, 0>>
        assert {:ok, ^subscribe, ctx} = Transport.recv_stream(ctx, control, byte_size(subscribe))

        # SUBSCRIBE_OK: request=0, alias=0, expires=0, publisher order, content exists,
        # largest location=(0, 0), no parameters.
        subscribe_ok = <<0x04, 0, 8, 0, 0, 0, 0, 1, 0, 0, 0>>
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, subscribe_ok)

        {:ok, subgroup, ctx} =
          Transport.open_stream(ctx, conn, direction: :unidirectional)

        object =
          IO.iodata_to_binary([
            # SubgroupIdExt: alias=0, group=0, subgroup=0, priority=0,
            # object delta=0, extension-header byte length=0.
            <<0x15, 0, 0, 0, 0, 0, 0>>,
            encode_varint(byte_size(catalog)),
            catalog
          ])

        {:ok, _send, _ctx} = Transport.send_stream(ctx, subgroup, object, finish: true)

        media_subscribe = <<0x03, 0, 17, 2, 1, 3, "bbb", 5, "1.m4s", 127, 0, 1, 2, 0>>

        assert {:ok, ^media_subscribe, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(media_subscribe))

        media_ok = <<0x04, 0, 8, 2, 1, 0, 0, 1, 10, 0, 0>>
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, media_ok)

        ctx = send_objects(ctx, conn, 1, 10, [{0, "fragment-10a"}, {1, "fragment-10b"}])
        ctx = send_objects(ctx, conn, 1, 11, [{0, "fragment-11"}], :abort)

        init_subscribe = <<0x03, 0, 17, 4, 1, 3, "bbb", 5, "0.mp4", 127, 0, 1, 2, 0>>
        assert {:ok, ^init_subscribe, ctx} = recv_exact(ctx, control, init_subscribe)

        init_ok = <<0x04, 0, 8, 4, 2, 0, 0, 1, 0, 0, 0>>
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, init_ok)
        ctx = send_objects(ctx, conn, 2, 0, [{0, "init-segment"}])

        unsubscribe_init = <<0x0A, 0, 1, 4>>
        assert {:ok, ^unsubscribe_init, ctx} = recv_exact(ctx, control, unsubscribe_init)

        capture_media_subscribe =
          <<0x03, 0, 21, 6, 1, 3, "bbb", 9, "video.m4s", 127, 0, 1, 2, 0>>

        assert {:ok, ^capture_media_subscribe, ctx} =
                 recv_exact(ctx, control, capture_media_subscribe)

        capture_media_ok = <<0x04, 0, 8, 6, 3, 0, 0, 1, 19, 0, 0>>
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, capture_media_ok)
        ctx = send_objects(ctx, conn, 3, 20, [{0, "fragment-20"}])
        ctx = send_objects(ctx, conn, 3, 19, [{0, "fragment-19"}])

        unsubscribe_media = <<0x0A, 0, 1, 6>>
        assert {:ok, ^unsubscribe_media, ctx} = recv_exact(ctx, control, unsubscribe_media)

        missing_subscribe =
          <<0x03, 0, 19, 8, 1, 3, "bbb", 7, "missing", 127, 0, 1, 2, 0>>

        assert {:ok, ^missing_subscribe, ctx} = recv_exact(ctx, control, missing_subscribe)

        subscribe_error = <<0x05, 0, 12, 8, 4, 9, "not found">>
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, subscribe_error)

        assert {:ok, {:connection_event, ^conn, :closed, %{error_code: 0}}, _ctx} =
                 receive_closed(ctx, conn, 1_000)

        :ok
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :cloudflare_draft_14,
               transport: {Support, network: network, profile: :draft_14},
               timeout: 1_000
             )

    track = %MOQX.TrackRef{namespace: ["bbb"], track: ".catalog"}
    assert {:ok, %MOQX.Subscription{track: ^track}} = MOQX.subscribe(client, track)

    assert_receive {:moqx, ^client, {:catalog, %MOQX.Catalog{version: 1} = decoded}}, 1_000
    assert [%MOQX.Catalog.Track{name: "video.m4s"}] = decoded.tracks

    media = %MOQX.TrackRef{namespace: ["bbb"], track: "1.m4s"}
    assert {:ok, %MOQX.Subscription{} = media_subscription} = MOQX.subscribe(client, media)

    assert_receive {:moqx, ^client,
                    {:object,
                     %MOQX.Object{
                       subscription: ^media_subscription,
                       group_id: 10,
                       object_id: 0,
                       payload: "fragment-10a"
                     }}},
                   1_000

    path = Path.join(tmp_dir, "capture.mp4")

    assert {:ok,
            %MOQX.CMAF.Capture{
              path: ^path,
              track: %MOQX.Catalog.Track{name: "video.m4s"},
              object_count: 2,
              first_group_id: 19,
              last_group_id: 20
            }} = MOQX.CMAF.capture(client, decoded, path, objects: 2, timeout: 1_000)

    assert File.read!(path) == "init-segmentfragment-19fragment-20"

    missing = %MOQX.TrackRef{namespace: ["bbb"], track: "missing"}
    assert {:ok, missing_subscription} = MOQX.subscribe(client, missing)

    assert_receive {:moqx, ^client,
                    {:subscription_error, ^missing_subscription,
                     %MOQX.ProtocolError{
                       protocol: :cloudflare_draft_14,
                       operation: :subscribe,
                       code: 4,
                       reason: "not found"
                     }}},
                   1_000

    assert_receive {:moqx, ^client,
                    {:object,
                     %MOQX.Object{
                       subscription: ^media_subscription,
                       group_id: 10,
                       object_id: 1,
                       payload: "fragment-10b"
                     }}},
                   1_000

    assert_receive {:moqx, ^client,
                    {:object,
                     %MOQX.Object{
                       subscription: ^media_subscription,
                       group_id: 11,
                       object_id: 0,
                       payload: "fragment-11"
                     }}},
                   1_000

    assert :ok = MOQX.close(client)

    assert :ok = Task.await(relay, 1_000)
  end

  defp catalog_payload do
    JSON.encode!(%{
      "version" => 1,
      "streamingFormat" => 1,
      "streamingFormatVersion" => "0.2",
      "supportsDeltaUpdates" => false,
      "commonTrackFields" => %{"namespace" => "bbb", "packaging" => "cmaf"},
      "tracks" => [
        %{
          "name" => "video.m4s",
          "initTrack" => "0.mp4",
          "selectionParams" => %{"codec" => "avc1.42C01F"}
        }
      ]
    })
  end

  defp encode_varint(value) when value < 64, do: <<value>>
  defp encode_varint(value) when value < 16_384, do: <<value ||| 0x4000::16>>

  defp send_objects(ctx, conn, alias_id, group_id, objects) do
    send_objects(ctx, conn, alias_id, group_id, objects, :finish)
  end

  defp send_objects(ctx, conn, alias_id, group_id, objects, completion) do
    {:ok, subgroup, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)

    payload =
      [
        <<0x15>>,
        encode_varint(alias_id),
        encode_varint(group_id),
        <<0, 0>>,
        Enum.map(objects, fn {delta, object_payload} ->
          [
            encode_varint(delta),
            <<0>>,
            encode_varint(byte_size(object_payload)),
            object_payload
          ]
        end)
      ]
      |> IO.iodata_to_binary()

    {:ok, _send, ctx} =
      Transport.send_stream(ctx, subgroup, payload, finish: completion == :finish)

    case completion do
      :finish -> ctx
      :abort -> elem(Transport.abort_sending(ctx, subgroup, 99), 1)
    end
  end

  defp recv_exact(ctx, stream, expected) do
    Transport.recv_stream(ctx, stream, byte_size(expected))
  end

  defp receive_closed(ctx, conn, timeout) do
    case Transport.receive_event(ctx, timeout) do
      {:ok, {:connection_event, ^conn, :closed, _metadata} = event, ctx} ->
        {:ok, event, ctx}

      {:ok, _event, ctx} ->
        receive_closed(ctx, conn, timeout)

      {:unknown, _message, ctx} ->
        receive_closed(ctx, conn, timeout)

      other ->
        other
    end
  end
end
