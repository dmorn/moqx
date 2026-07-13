defmodule MOQX.Integration.CloudflareCatalogTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  @tag :tmp_dir
  test "captures Cloudflare's public Big Buck Bunny H.264 track", %{tmp_dir: tmp_dir} do
    assert {:ok, client} =
             MOQX.connect("moqt://draft-14.cloudflare.mediaoverquic.com:443",
               protocol: :cloudflare_draft_14,
               timeout: 10_000
             )

    track = %MOQX.TrackRef{namespace: ["bbb"], track: ".catalog"}
    assert {:ok, %MOQX.Subscription{track: ^track}} = MOQX.subscribe(client, track)

    assert_receive {:moqx, ^client, {:catalog, %MOQX.Catalog{} = catalog}}, 10_000
    assert catalog.version == 1
    assert catalog.tracks != []

    path = Path.join(tmp_dir, "cloudflare-bbb.mp4")

    assert {:ok,
            %MOQX.CMAF.Capture{
              path: ^path,
              track: %MOQX.Catalog.Track{codec: "avc1" <> _codec},
              object_count: 30,
              init_bytes: init_bytes,
              media_bytes: media_bytes
            }} = MOQX.CMAF.capture(client, catalog, path, objects: 30, timeout: 15_000)

    assert init_bytes > 0
    assert media_bytes > 0
    assert {:ok, %{size: size}} = File.stat(path)
    assert size == init_bytes + media_bytes
    assert :ok = MOQX.close(client)
  end
end
