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
            }} = MOQX.Catalog.decode(payload)

    assert %MOQX.Catalog.Track{
             namespace: "bbb",
             name: "video.m4s",
             init_track: "video.mp4",
             packaging: "cmaf",
             codec: "avc1.42C01F",
             width: 1280,
             height: 720
           } = track

    assert %MOQX.TrackRef{namespace: ["bbb"], track: "video.m4s"} =
             Track.track_ref(track)
  end

  test "decodes current Moqtail CMSF metadata and resolves its catalog address" do
    init = <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso6">>

    payload =
      JSON.encode!(%{
        "version" => 1,
        "generatedAt" => 1_785_163_690_110,
        "tracks" => [
          %{
            "name" => "audio",
            "renderGroup" => 1,
            "packaging" => "cmaf",
            "isLive" => true,
            "role" => "audio",
            "codec" => "mp4a.40.2",
            "bitrate" => 3_072_000,
            "timescale" => 48_000,
            "altGroup" => 2,
            "initData" => Base.encode64("audio-init")
          },
          %{
            "name" => "video-720p",
            "renderGroup" => 1,
            "packaging" => "cmaf",
            "isLive" => true,
            "role" => "video",
            "codec" => "avc1.42C01F",
            "width" => 1280,
            "height" => 720,
            "bitrate" => 2_000_000,
            "timescale" => 30,
            "framerate" => 30,
            "altGroup" => 1,
            "initData" => Base.encode64(init)
          }
        ]
      })

    assert {:ok, %MOQX.Catalog{version: 1, format: :moqtail_cmsf} = catalog} =
             MOQX.Catalog.decode(payload, namespace: ["moqtail", "testsrc"])

    assert [
             _,
             %Track{
               name: "video-720p",
               role: "video",
               packaging: "cmaf",
               codec: "avc1.42C01F",
               width: 1280,
               height: 720,
               bitrate: 2_000_000,
               timescale: 30,
               init_data: ^init
             } = track
           ] = catalog.tracks

    assert %MOQX.TrackRef{
             namespace: ["moqtail", "testsrc"],
             track: "video-720p"
           } = MOQX.Catalog.track_ref(catalog, track)
  end

  test "returns typed actionable errors for invalid current CMSF catalogs" do
    assert {:error,
            %MOQX.Catalog.Error{
              path: [:version],
              reason: :unsupported,
              value: 2
            }} = MOQX.Catalog.decode(~s({"version":2,"tracks":[]}))

    assert {:error,
            %MOQX.Catalog.Error{
              path: [:version],
              reason: :invalid_type,
              value: "1"
            }} = MOQX.Catalog.decode(~s({"version":"1","tracks":[]}))

    invalid_tracks = [
      {%{"packaging" => "cmaf", "role" => "video", "codec" => "avc1.42C01F"}, [:tracks, 0, :name],
       :required},
      {%{"name" => "video", "packaging" => "mpegts", "role" => "video"}, [:tracks, 0, :packaging],
       :unsupported},
      {%{"name" => "video", "packaging" => "cmaf", "role" => "caption"}, [:tracks, 0, :role],
       :unsupported},
      {%{"name" => "video", "packaging" => "cmaf", "role" => "video"}, [:tracks, 0, :codec],
       :required},
      {%{"name" => "video", "packaging" => "cmaf", "role" => "video", "codec" => 42},
       [:tracks, 0, :codec], :invalid_type},
      {%{
         "name" => "video",
         "packaging" => "cmaf",
         "role" => "video",
         "codec" => "avc1.42C01F",
         "width" => "1280"
       }, [:tracks, 0, :width], :invalid_type},
      {%{
         "name" => "video",
         "packaging" => "cmaf",
         "role" => "video",
         "codec" => "avc1.42C01F",
         "timescale" => 0
       }, [:tracks, 0, :timescale], :out_of_range},
      {%{
         "name" => "video",
         "packaging" => "cmaf",
         "role" => "video",
         "codec" => "avc1.42C01F",
         "initData" => "not base64"
       }, [:tracks, 0, :init_data], :invalid_base64}
    ]

    for {track, path, reason} <- invalid_tracks do
      payload = JSON.encode!(%{"version" => 1, "tracks" => [track]})

      assert {:error, %MOQX.Catalog.Error{path: ^path, reason: ^reason}} =
               MOQX.Catalog.decode(payload)
    end
  end
end
