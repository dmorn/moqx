defmodule MOQX.Integration.MoqtailDraft16CatalogTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "receives Moqtail's public CMSF catalog and subscribes to its selected track" do
    assert {:ok, client} =
             MOQX.connect("moqt://relay.moqtail.dev:443",
               protocol: :draft_16,
               timeout: 10_000
             )

    try do
      track = %MOQX.TrackRef{namespace: ["moqtail", "testsrc"], track: "catalog"}

      assert {:ok, %MOQX.Subscription{} = subscription} =
               MOQX.subscribe(client, track, start: :next_group, priority: 127)

      assert_receive {:moqx, ^client,
                      %MOQX.Event.SubscriptionAccepted{subscription: ^subscription}},
                     10_000

      assert :ok = MOQX.update_subscription(client, subscription, priority: 126)

      assert_receive {:moqx, ^client,
                      %MOQX.Event.SubscriptionUpdated{subscription: ^subscription}},
                     10_000

      assert_receive {:moqx, ^client,
                      %MOQX.Event.CatalogReceived{
                        subscription: ^subscription,
                        catalog:
                          %MOQX.Catalog{
                            version: 1,
                            format: :moqtail_cmsf
                          } = catalog
                      }},
                     10_000

      assert {:ok,
              %MOQX.Catalog.Track{
                role: "video",
                packaging: "cmaf",
                codec: "avc1" <> _codec,
                init_data: init_data
              } = video} = MOQX.Catalog.select_h264(catalog)

      assert is_binary(init_data) and byte_size(init_data) > 0

      media_ref = MOQX.Catalog.track_ref(catalog, video)
      assert media_ref.namespace == ["moqtail", "testsrc"]
      assert media_ref.track == video.name

      assert {:ok, media_subscription} =
               MOQX.subscribe(client, media_ref, start: :next_group, priority: 127)

      assert_receive {:moqx, ^client,
                      %MOQX.Event.SubscriptionAccepted{
                        subscription: ^media_subscription
                      }},
                     10_000

      assert_receive {:moqx, ^client,
                      %MOQX.Event.ObjectReceived{
                        object: %MOQX.Object{
                          subscription: ^media_subscription,
                          payload: media_payload
                        }
                      }},
                     10_000

      assert byte_size(media_payload) > 0
    after
      _result = MOQX.close(client)
    end
  end
end
