defmodule MOQX.CMAFPublisherTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQTDraft16.{Codec, SubgroupDecoder}
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  @tag :tmp_dir
  test "splits initialization data from complete moof fragments", %{tmp_dir: tmp_dir} do
    init = box("ftyp", "brand") <> box("moov", "metadata")
    fragment_0 = box("moof", "fragment-0") <> box("mdat", "payload-0")
    fragment_1 = box("moof", "fragment-1") <> box("mdat", "payload-1")
    path = Path.join(tmp_dir, "sample.mp4")
    File.write!(path, init <> fragment_0 <> fragment_1)

    assert {:ok, ^init, [^fragment_0, ^fragment_1]} = MOQX.CMAF.read_fragments(path)
  end

  @tag :tmp_dir
  test "rejects a flat or malformed MP4", %{tmp_dir: tmp_dir} do
    flat_path = Path.join(tmp_dir, "flat.mp4")
    File.write!(flat_path, box("ftyp", "brand") <> box("moov", "metadata"))
    assert {:error, :not_fragmented_mp4} = MOQX.CMAF.read_fragments(flat_path)

    malformed_path = Path.join(tmp_dir, "bad.mp4")
    File.write!(malformed_path, <<0, 0, 0, 100, "moof", 1, 2, 3>>)
    assert {:error, :invalid_iso_bmff} = MOQX.CMAF.read_fragments(malformed_path)
  end

  test "rejects invalid draft-16 publication timing before reading the file" do
    client = %MOQX.Client{pid: self(), protocol: :draft_16}

    assert {:error, :invalid_publication_timing_options} =
             MOQX.CMAF.publish_file(client, "/does/not/exist",
               namespace: ["operator", "camera"],
               catalog_repetitions: 0
             )
  end

  @tag :tmp_dir
  test "publishes a Moqtail CMSF catalog and CMAF fragment after draft-16 readiness", %{
    tmp_dir: tmp_dir
  } do
    init = box("ftyp", "brand") <> box("moov", "metadata")
    fragment = box("moof", "fragment-0") <> box("mdat", "payload-0")
    path = Path.join(tmp_dir, "sample.mp4")
    File.write!(path, init <> fragment)

    {:ok, network} = Support.start_network()
    parent = self()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :draft_16)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, control, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        setup = Codec.client_setup(URI.parse("moqt://localhost:#{port}"))
        assert {:ok, ^setup, ctx} = Transport.recv_stream(ctx, control, byte_size(setup))

        {:ok, _send, ctx} =
          Transport.send_stream(ctx, control, <<0x21, 0, 3, 1, 2, 4>>)

        namespace = ["operator", "camera"]
        publish_namespace = Codec.publish_namespace(0, namespace)

        assert {:ok, ^publish_namespace, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_namespace))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x07, 0, 2, 0, 0>>)

        catalog_ref = %MOQX.TrackRef{namespace: namespace, track: "catalog"}
        catalog_publish = Codec.publish_track(2, catalog_ref, 0)

        assert {:ok, ^catalog_publish, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(catalog_publish))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x1E, 0, 2, 2, 0>>)

        media_ref = %MOQX.TrackRef{namespace: namespace, track: "video"}
        media_publish = Codec.publish_track(4, media_ref, 1)

        assert {:ok, ^media_publish, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(media_publish))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x1E, 0, 2, 4, 0>>)

        {:ok, catalog_stream, ctx} =
          Transport.accept_stream(ctx, conn, [active: true], 1_000)

        {:ok, ctx} = Transport.set_active(ctx, catalog_stream, true)
        {:ok, catalog_bytes, ctx} = recv_stream_data(ctx, catalog_stream)

        assert {:ok, _decoder, [catalog_object]} =
                 SubgroupDecoder.push(%SubgroupDecoder{}, catalog_bytes)

        assert catalog_object.track_alias == 0
        assert catalog_object.priority == 0

        assert JSON.decode!(catalog_object.payload) == %{
                 "version" => 1,
                 "tracks" => [
                   %{
                     "name" => "video",
                     "role" => "video",
                     "packaging" => "cmaf",
                     "codec" => "avc1.42C01F",
                     "timescale" => 90_000,
                     "initData" => Base.encode64(init)
                   }
                 ]
               }

        {:ok, refreshed_catalog_stream, ctx} =
          Transport.accept_stream(ctx, conn, [active: true], 1_000)

        {:ok, ctx} = Transport.set_active(ctx, refreshed_catalog_stream, true)

        {:ok, refreshed_catalog_bytes, ctx} =
          recv_stream_data(ctx, refreshed_catalog_stream)

        assert {:ok, _decoder, [refreshed_catalog]} =
                 SubgroupDecoder.push(%SubgroupDecoder{}, refreshed_catalog_bytes)

        assert %{track_alias: 0, group_id: 1, object_id: 0, priority: 0} =
                 refreshed_catalog

        {:ok, media_stream, ctx} =
          Transport.accept_stream(ctx, conn, [active: true], 1_000)

        {:ok, ctx} = Transport.set_active(ctx, media_stream, true)
        {:ok, media_bytes, ctx} = recv_stream_data(ctx, media_stream)

        assert {:ok, _decoder, [media_object]} =
                 SubgroupDecoder.push(%SubgroupDecoder{}, media_bytes)

        assert %{
                 track_alias: 1,
                 group_id: 0,
                 object_id: 0,
                 priority: 1,
                 payload: ^fragment
               } = media_object

        catalog_done = Codec.publish_done(2, 2, 2, "track ended")

        assert {:ok, ^catalog_done, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(catalog_done))

        media_done = Codec.publish_done(4, 2, 1, "track ended")

        assert {:ok, ^media_done, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(media_done))

        namespace_done = Codec.publish_namespace_done(0)

        assert {:ok, ^namespace_done, _ctx} =
                 Transport.recv_stream(ctx, control, byte_size(namespace_done))

        :ok
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :draft_16,
               transport: {Support, network: network, profile: :draft_16},
               timeout: 1_000
             )

    assert {:ok, published} =
             MOQX.CMAF.publish_file(client, path,
               namespace: ["operator", "camera"],
               catalog_repetitions: 2,
               catalog_interval: 0,
               timeout: 1_000
             )

    assert published.init_track == nil
    assert MOQX.PublishedTrack.track_ref(published.catalog_track).track == "catalog"
    assert MOQX.PublishedTrack.track_ref(published.media_track).track == "video"

    assert :ok = MOQX.finish_publication(client, published.publication)
    assert :ok = Task.await(relay, 3_000)
  end

  defp recv_stream_data(ctx, stream) do
    case Transport.receive_event(ctx, 1_000) do
      {:ok, {:stream_data, ^stream, data, _metadata}, ctx} ->
        {:ok, data, ctx}

      {:ok, _event, ctx} ->
        recv_stream_data(ctx, stream)

      other ->
        other
    end
  end

  defp box(type, payload) do
    <<byte_size(payload) + 8::32, type::binary-size(4), payload::binary>>
  end
end
