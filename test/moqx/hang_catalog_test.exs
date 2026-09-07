defmodule MOQX.HangCatalogTest do
  use ExUnit.Case, async: true

  test "H.264 selectors rank typed HANG renditions without coercing them to CMSF" do
    video = %{
      "a-low" => %{
        "codec" => "avc1.64001f",
        "codedWidth" => 1280,
        "codedHeight" => 720,
        "container" => %{"kind" => "cmaf", "init" => "aW5pdA=="}
      },
      "z-high" => %{
        "codec" => "avc3.640028",
        "codedWidth" => 1920,
        "codedHeight" => 1080,
        "container" => %{"kind" => "cmaf", "init" => "aW5pdA=="}
      },
      "legacy" => %{"codec" => "avc1.42001e", "codedWidth" => 640, "codedHeight" => 360},
      "loc" => %{"codec" => "avc1.42001e", "container" => %{"kind" => "loc"}},
      "ignored-av1" => %{"codec" => "av01.0.08M.10", "codedWidth" => 3840, "codedHeight" => 2160},
      "ignored-container" => %{"codec" => "avc1.640028", "container" => %{"kind" => "future"}},
      "ignored-codec" => %{"codec" => "avc1future"}
    }

    payload =
      JSON.encode!(%{
        "video" => %{"renditions" => video},
        "audio" => %{
          "renditions" => %{
            "ignored-audio" => %{
              "codec" => "avc1.640028",
              "sampleRate" => 48_000,
              "numberOfChannels" => 2
            }
          }
        }
      })

    assert {:ok, catalog} = MOQX.Catalog.decode(payload, format: :hang)

    assert Enum.map(MOQX.Catalog.h264_tracks(catalog), & &1.name) == [
             "z-high",
             "a-low",
             "legacy",
             "loc"
           ]

    assert {:ok, selected} = MOQX.Catalog.select_h264(catalog)
    assert selected.name == "z-high"
    assert selected.decoder.coded_width == 1920
    assert selected.container.init == "init"
    assert selected.packaging == nil
    assert selected.init_data == nil
    assert selected.width == nil
  end

  test "HANG jitter preserves fractional milliseconds and rejects negative or nonnumeric values" do
    for jitter <- [0, 0.0, 16.667, 23.22] do
      payload =
        JSON.encode!(%{
          "video" => %{"renditions" => %{"v" => %{"codec" => "avc1.42001e", "jitter" => jitter}}}
        })

      assert {:ok, catalog} = MOQX.Catalog.decode(payload, format: :hang)
      assert catalog.media.video.renditions["v"].jitter === jitter
      assert {:ok, encoded} = MOQX.Catalog.encode(catalog)
      assert JSON.decode!(encoded)["video"]["renditions"]["v"]["jitter"] === jitter
    end

    for jitter <- [-0.1, -1, "16.667", nil] do
      payload =
        JSON.encode!(%{
          "video" => %{"renditions" => %{"v" => %{"codec" => "avc1.42001e", "jitter" => jitter}}}
        })

      assert {:error,
              %MOQX.Catalog.Error{path: [:video, :renditions, 0, :jitter], reason: :invalid_type}} =
               MOQX.Catalog.decode(payload, format: :hang)
    end
  end

  test "HANG preserves typed rendition metadata, initialization and extensions through encoding" do
    json =
      ~s({"video":{"renditions":{"720p":{"codec":"avc1.64001f","codedWidth":1280,"codedHeight":720,"description":"01AB","container":{"kind":"cmaf","init":"aW5pdA==","vendor":7},"vendor":{"enabled":true}}},"display":{"width":1280,"height":720},"rotation":90,"vendor":"section"},"audio":{"renditions":{"opus":{"codec":"opus","sampleRate":48000,"numberOfChannels":2}}},"vendor":"root"})

    assert {:ok, catalog} =
             MOQX.Catalog.decode(json, format: :hang, namespace: ["room", "alice.hang"])

    assert catalog.format == :hang
    video = catalog.media.video.renditions["720p"]
    assert video.decoder.description == <<1, 171>>
    assert video.decoder.coded_width == 1280
    assert video.container.init == "init"
    assert video.container.extensions == %{"vendor" => 7}
    assert video.extensions == %{"vendor" => %{"enabled" => true}}
    assert catalog.media.video.display == %{"width" => 1280, "height" => 720}
    assert catalog.media.audio.renditions["opus"].decoder.sample_rate == 48_000

    assert MOQX.Catalog.track_ref(catalog, video) == %MOQX.TrackRef{
             namespace: ["room", "alice.hang"],
             track: "720p"
           }

    changed = put_in(catalog.media.video.renditions["720p"].decoder.description, <<2, 255>>)
    assert {:ok, encoded} = MOQX.Catalog.encode(changed)
    decoded = JSON.decode!(encoded)
    assert decoded["video"]["renditions"]["720p"]["description"] == "02ff"
    assert decoded["vendor"] == "root"
    assert decoded["video"]["vendor"] == "section"
    assert {:ok, roundtrip} = MOQX.Catalog.decode(encoded, format: :hang)
    assert roundtrip.media.video.renditions["720p"].decoder.description == <<2, 255>>
  end

  test "malformed HANG metadata yields typed errors without exposing input values" do
    for bad <- [
          %{"video" => []},
          %{
            "audio" => %{
              "renditions" => %{
                "a" => %{"codec" => "opus", "sampleRate" => 0, "numberOfChannels" => 2}
              }
            }
          },
          %{
            "video" => %{
              "renditions" => %{
                "secret-track" => %{"codec" => "avc1", "description" => "secret-token"}
              }
            }
          },
          %{
            "video" => %{
              "renditions" => %{
                "v" => %{
                  "codec" => "avc1",
                  "container" => %{"kind" => "cmaf", "init" => "secret-token"}
                }
              }
            }
          },
          %{
            "video" => %{
              "renditions" => %{
                "v" => %{"codec" => "avc1", "timeline" => %{"track" => "index", "timescale" => 0}}
              }
            }
          },
          %{
            "audio" => %{
              "renditions" => %{
                "a" => %{
                  "codec" => "pcm",
                  "sampleRate" => 48_000,
                  "numberOfChannels" => 2,
                  "description" => "00"
                }
              }
            }
          }
        ] do
      assert {:error, %MOQX.Catalog.Error{value: nil} = error} =
               MOQX.Catalog.decode(JSON.encode!(bad), format: :hang)

      refute inspect(error) =~ "secret"
    end
  end

  test "plain and sync-flushed raw DEFLATE catalogs are bounded and interoperable" do
    # Independent Python zlib.compressobj(wbits=-15), Z_SYNC_FLUSH, marker removed.
    compressed = Base.decode16!("AAAE0500")
    assert {:ok, empty} = MOQX.Catalog.decode(compressed, format: :hang, compression: :deflate)
    assert empty.tracks == []
    assert {:ok, ^compressed} = MOQX.Catalog.encode(empty, compression: :deflate)

    assert {:error, %MOQX.Catalog.Error{reason: :too_large}} =
             MOQX.Catalog.decode("{}", format: :hang, max_bytes: 1)

    assert {:error, %MOQX.Catalog.Error{reason: :too_large}} =
             MOQX.Catalog.decode(compressed, format: :hang, compression: :deflate, max_bytes: 1)

    assert {:error, %MOQX.Catalog.Error{}} =
             MOQX.Catalog.decode(<<255, 255>>, format: :hang, compression: :deflate)
  end

  test "rendition addressing resolves relative broadcasts and preserves unsupported metadata" do
    json =
      ~s({"video":{"renditions":{"source":{"codec":"future-codec","broadcast":"./source","container":{"kind":"future-container","init":{"extension":true}}},"escape":{"codec":"avc1","broadcast":"../../outside"}}}})

    assert {:ok, catalog} =
             MOQX.Catalog.decode(json, format: :hang, namespace: ["room", "transcode"])

    source = catalog.media.video.renditions["source"]

    assert MOQX.Catalog.track_ref(catalog, source) == %MOQX.TrackRef{
             namespace: ["room", "source"],
             track: "source"
           }

    assert source.metadata_status == :unknown_container

    assert {:error, :broadcast_outside_root} =
             MOQX.Catalog.track_ref(catalog, catalog.media.video.renditions["escape"])

    assert {:ok, encoded} = MOQX.Catalog.encode(catalog)

    assert JSON.decode!(encoded)["video"]["renditions"]["source"]["container"]["init"] == %{
             "extension" => true
           }
  end

  test "encoding invalid typed metadata and compressed expansion return bounded errors" do
    {:ok, catalog} = MOQX.Catalog.decode("{}", format: :hang)

    assert {:error, %MOQX.Catalog.Error{value: nil}} =
             MOQX.Catalog.encode(%{catalog | media: %{video: :invalid}})

    {:ok, big} =
      MOQX.Catalog.decode(JSON.encode!(%{"extension" => String.duplicate("a", 100_000)}),
        format: :hang
      )

    {:ok, compressed} = MOQX.Catalog.encode(big, compression: :deflate)
    assert byte_size(compressed) < 1000

    assert {:error, %MOQX.Catalog.Error{reason: :too_large}} =
             MOQX.Catalog.decode(compressed,
               format: :hang,
               compression: :deflate,
               max_bytes: 1000
             )

    assert {:error, %MOQX.Catalog.Error{reason: :too_large}} =
             MOQX.Catalog.encode(catalog, compression: :deflate, max_encoded_bytes: 1)
  end
end
