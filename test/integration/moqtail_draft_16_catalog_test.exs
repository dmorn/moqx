defmodule MOQX.Integration.MoqtailDraft16CatalogTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "receives Moqtail's public draft-16 catalog as a typed object" do
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
                      %MOQX.Event.ObjectReceived{
                        object: %MOQX.Object{
                          subscription: ^subscription,
                          payload: payload
                        }
                      }},
                     10_000

      assert {:ok, %{"version" => 1, "tracks" => tracks}} = JSON.decode(payload)
      assert tracks != []
    after
      _result = MOQX.close(client)
    end
  end
end
