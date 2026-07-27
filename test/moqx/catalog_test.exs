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

  test "decodes and selects a current Moqtail CMSF track through the catalog address" do
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

    assert {:ok,
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
            } = track} = MOQX.Catalog.select_h264(catalog)

    assert %MOQX.TrackRef{
             namespace: ["moqtail", "testsrc"],
             track: "video-720p"
           } = MOQX.Catalog.track_ref(catalog, track)
  end

  test "selects compatible H.264 tracks deterministically" do
    init_data = Base.encode64("init")

    payload =
      JSON.encode!(%{
        "version" => 1,
        "tracks" => [
          moqtail_track("ignored-no-init", 3840, 2160, 8_000_000, nil),
          moqtail_track("z-low", 1920, 1080, 1_000_000, init_data),
          moqtail_track("ignored-av1", 3840, 2160, 8_000_000, init_data, "av01.0.08M.10"),
          moqtail_track("b-high", 1920, 1080, 2_000_000, init_data),
          moqtail_track("a-high", 1920, 1080, 2_000_000, init_data)
        ]
      })

    assert {:ok, catalog} = MOQX.Catalog.decode(payload, namespace: ["live"])

    assert Enum.map(MOQX.Catalog.h264_tracks(catalog), & &1.name) ==
             ["a-high", "b-high", "z-low"]

    assert {:ok, %Track{name: "a-high"}} = MOQX.Catalog.select_h264(catalog)
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

  defp moqtail_track(name, width, height, bitrate, init_data, codec \\ "avc1.42C01F") do
    %{
      "name" => name,
      "packaging" => "cmaf",
      "role" => "video",
      "codec" => codec,
      "width" => width,
      "height" => height,
      "bitrate" => bitrate,
      "timescale" => 90_000
    }
    |> then(fn track -> if init_data, do: Map.put(track, "initData", init_data), else: track end)
  end
end
