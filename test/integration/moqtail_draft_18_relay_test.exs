defmodule MOQX.Integration.MoqtailDraft18RelayTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :moqtail_draft18_relay

  @relay "moqt://moqtail-draft18-relay:4433"
  @ca_file "/certs/ca.pem"

  test "publisher and subscriber roundtrip through the pinned draft-18 relay" do
    namespace = ["integration", Integer.to_string(System.unique_integer([:positive]))]
    payload = "pinned-draft18-object"

    assert {:ok, publisher} = connect()

    try do
      assert {:ok, publication} = MOQX.publish(publisher, namespace)

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationReady{publication: ^publication}},
                     5_000

      assert {:ok, track} = MOQX.add_track(publisher, publication, "video")

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationSubscriberJoined{track: ^track}},
                     5_000

      assert {:ok, subscriber} = connect()

      try do
        track_ref = %MOQX.TrackRef{namespace: namespace, track: "video"}
        assert {:ok, subscription} = MOQX.subscribe(subscriber, track_ref)

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubscriptionAccepted{subscription: ^subscription}},
                       5_000

        assert :ok =
                 MOQX.publish_object(publisher, track, %MOQX.Object{
                   group_id: 1,
                   subgroup_id: 0,
                   object_id: 0,
                   publisher_priority: 127,
                   end_of_group?: true,
                   payload: payload
                 })

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.ObjectReceived{
                          object: %MOQX.Object{
                            subscription: ^subscription,
                            group_id: 1,
                            object_id: 0,
                            payload: ^payload
                          }
                        }},
                       5_000

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubgroupEnded{
                          subscription: ^subscription,
                          group_id: 1,
                          outcome: :complete,
                          end_of_group?: true
                        }},
                       5_000
      after
        _result = MOQX.close(subscriber)
      end
    after
      _result = MOQX.close(publisher)
    end
  end

  defp connect do
    MOQX.connect(@relay,
      protocol: :draft_18,
      connect_options: [cacertfile: @ca_file],
      timeout: 5_000
    )
  end
end
