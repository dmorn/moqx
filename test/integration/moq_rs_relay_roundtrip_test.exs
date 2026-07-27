defmodule MOQX.Integration.MoqRsRelayRoundtripTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :moq_rs_relay

  @relay "moqt://moq-rs-relay:443"
  @ca_file "/certs/ca.pem"

  test "public publisher and subscriber APIs roundtrip through the Docker relay" do
    namespace = ["integration", Integer.to_string(System.unique_integer([:positive]))]

    assert {:ok, publisher} = connect()

    try do
      assert {:ok, publication} = MOQX.publish(publisher, namespace)

      assert {:ok, catalog_track} =
               MOQX.add_track(publisher, publication, ".catalog", retention: :latest)

      assert {:ok, media_track} =
               MOQX.add_track(publisher, publication, "video.m4s", retention: :latest)

      assert :ok =
               MOQX.publish_object(publisher, catalog_track, %MOQX.Object{
                 group_id: 0,
                 subgroup_id: 0,
                 object_id: 0,
                 payload: catalog_payload(namespace)
               })

      assert :ok =
               MOQX.publish_object(publisher, media_track, %MOQX.Object{
                 group_id: 42,
                 subgroup_id: 0,
                 object_id: 0,
                 payload: "docker-relay-fragment"
               })

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationReady{publication: ^publication}},
                     5_000

      assert {:ok, subscriber} = connect()

      try do
        catalog_ref = %MOQX.TrackRef{namespace: namespace, track: ".catalog"}
        assert {:ok, catalog_subscription} = MOQX.subscribe(subscriber, catalog_ref)

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubscriptionAccepted{
                          subscription: ^catalog_subscription
                        }},
                       5_000

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.CatalogReceived{
                          catalog: %MOQX.Catalog{tracks: [%MOQX.Catalog.Track{} = catalog_track]}
                        }},
                       5_000

        assert catalog_track.namespace == Enum.join(namespace, "/")
        assert catalog_track.name == "video.m4s"

        media_ref = %MOQX.TrackRef{namespace: namespace, track: "video.m4s"}

        assert {:ok, media_subscription} =
                 MOQX.subscribe(subscriber, media_ref, start: :next_group)

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubscriptionAccepted{
                          subscription: ^media_subscription
                        }},
                       5_000

        # The pinned relay accepts NEXT_GROUP_START but does not apply the
        # decoded filter when attaching its retained subgroup reader.
        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.ObjectReceived{
                          object: %MOQX.Object{
                            subscription: ^media_subscription,
                            group_id: 42
                          }
                        }},
                       5_000

        assert :ok =
                 MOQX.publish_object(publisher, media_track, %MOQX.Object{
                   group_id: 43,
                   subgroup_id: 0,
                   object_id: 0,
                   payload: "docker-relay-fragment"
                 })

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.ObjectReceived{
                          object: %MOQX.Object{
                            subscription: ^media_subscription,
                            group_id: 43,
                            object_id: 0,
                            payload: "docker-relay-fragment"
                          }
                        }},
                       5_000

        assert :ok = MOQX.finish_publication(publisher, publication)

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubscriptionDone{
                          subscription: ^media_subscription,
                          completion: %MOQX.Subscription.Completion{
                            status: :track_ended,
                            # The pinned relay currently forwards zero here even
                            # after delivering subgroup streams (moq-rs TODO).
                            expected_streams: 0,
                            processed_streams: 2,
                            timed_out?: false
                          }
                        }},
                       5_000

        refute_receive {:moqx, ^publisher, %MOQX.Event.ProtocolFailed{}}, 100
      after
        _result = MOQX.close(subscriber)
      end
    after
      _result = MOQX.close(publisher)
    end
  end

  defp connect do
    MOQX.connect(@relay,
      protocol: :cloudflare_draft_14,
      connect_options: [cacertfile: @ca_file],
      timeout: 5_000
    )
  end

  defp catalog_payload(namespace) do
    JSON.encode!(%{
      "version" => 1,
      "streamingFormat" => 1,
      "streamingFormatVersion" => "0.2",
      "supportsDeltaUpdates" => false,
      "commonTrackFields" => %{
        "namespace" => Enum.join(namespace, "/"),
        "packaging" => "cmaf"
      },
      "tracks" => [
        %{
          "name" => "video.m4s",
          "initTrack" => "init.mp4",
          "selectionParams" => %{"codec" => "avc1.42C01F"}
        }
      ]
    })
  end
end
