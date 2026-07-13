defmodule MOQX.CatalogTest do
  use ExUnit.Case, async: true

  alias MOQX.Catalog.Track

  test "decodes the CMSF catalog shape deployed by Cloudflare" do
    payload =
      JSON.encode!(%{
        "version" => 1,
        "streamingFormat" => 1,
        "streamingFormatVersion" => "0.2",
        "supportsDeltaUpdates" => false,
        "commonTrackFields" => %{"namespace" => "bbb", "packaging" => "cmaf"},
        "tracks" => [
          %{
            "name" => "video.m4s",
            "initTrack" => "video.mp4",
            "selectionParams" => %{
              "codec" => "avc1.42C01F",
              "width" => 1280,
              "height" => 720
            }
          }
        ]
      })

    assert {:ok,
            %MOQX.Catalog{
              version: 1,
              streaming_format: 1,
              streaming_format_version: "0.2",
              supports_delta_updates: false,
              tracks: [track]
            } = decoded} = MOQX.Catalog.decode(payload)

    assert %MOQX.Catalog.Track{
             namespace: "bbb",
             name: "video.m4s",
             init_track: "video.mp4",
             packaging: "cmaf",
             codec: "avc1.42C01F",
             width: 1280,
             height: 720
           } = track

    assert {:ok, ^track} = MOQX.Catalog.select_h264(decoded)

    assert %MOQX.TrackRef{namespace: ["bbb"], track: "video.m4s"} =
             Track.track_ref(track)
  end
end
