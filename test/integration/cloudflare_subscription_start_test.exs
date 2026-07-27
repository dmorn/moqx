defmodule MOQX.Integration.CloudflareSubscriptionStartTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  @endpoint "moqt://draft-14.cloudflare.mediaoverquic.com:443"

  test "deployed relay accepts next-group start but currently replays the retained group" do
    namespace = ["moqx", "issue-28", Integer.to_string(System.unique_integer([:positive]))]

    assert {:ok, publisher} = connect()

    try do
      assert {:ok, publication} = MOQX.publish(publisher, namespace)

      assert {:ok, published_track} =
               MOQX.add_track(publisher, publication, "objects", retention: :latest)

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationReady{publication: ^publication}},
                     10_000

      assert :ok =
               MOQX.publish_object(publisher, published_track, %MOQX.Object{
                 group_id: 42,
                 subgroup_id: 0,
                 object_id: 0,
                 payload: "retained"
               })

      assert {:ok, subscriber} = connect()

      try do
        track_ref = %MOQX.TrackRef{namespace: namespace, track: "objects"}

        assert {:ok, subscription} =
                 MOQX.subscribe(subscriber, track_ref, start: :next_group)

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubscriptionAccepted{subscription: ^subscription}},
                       10_000

        # The deployed relay currently accepts NEXT_GROUP_START but attaches
        # its retained subgroup reader without applying the requested boundary.
        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.ObjectReceived{
                          object: %MOQX.Object{
                            subscription: ^subscription,
                            group_id: 42,
                            payload: "retained"
                          }
                        }},
                       10_000

        assert :ok =
                 MOQX.publish_object(publisher, published_track, %MOQX.Object{
                   group_id: 43,
                   subgroup_id: 0,
                   object_id: 0,
                   payload: "next"
                 })

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.ObjectReceived{
                          object: %MOQX.Object{
                            subscription: ^subscription,
                            group_id: 43,
                            payload: "next"
                          }
                        }},
                       10_000
      after
        _result = MOQX.close(subscriber)
      end
    after
      _result = MOQX.close(publisher)
    end
  end

  defp connect do
    MOQX.connect(@endpoint,
      protocol: :cloudflare_draft_14,
      timeout: 10_000
    )
  end
end
