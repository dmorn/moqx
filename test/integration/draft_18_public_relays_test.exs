defmodule MOQX.Integration.Draft18PublicRelaysTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :draft18_public_relays

  @moqtail_relay "moqt://relay.moqtail.dev:443"
  @cloudflare_relay "moqt://draft-18-interop.cloudflare.mediaoverquic.com:443"

  test "public APIs roundtrip an exact object through MOQtail's draft-18 relay" do
    assert_public_roundtrip(@moqtail_relay, "moqtail")
  end

  test "public APIs roundtrip an exact object through Cloudflare's draft-18 interop relay" do
    assert_public_roundtrip(@cloudflare_relay, "cloudflare")
  end

  defp assert_public_roundtrip(relay, relay_name) do
    namespace = [
      "moqx",
      "#{relay_name}-draft18-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    ]

    payload = "moqx-draft18-public-#{System.unique_integer([:positive])}"

    assert {:ok, publisher} = connect(relay)

    try do
      assert {:ok, publication} = MOQX.publish(publisher, namespace)

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationReady{publication: ^publication}},
                     10_000

      assert {:ok, track} =
               MOQX.add_track(publisher, publication, "data", delivery: :subgroup)

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationSubscriberJoined{track: ^track}},
                     10_000

      assert {:ok, subscriber} = connect(relay)

      try do
        track_ref = %MOQX.TrackRef{namespace: namespace, track: "data"}
        assert {:ok, subscription} = MOQX.subscribe(subscriber, track_ref)

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubscriptionAccepted{subscription: ^subscription}},
                       10_000

        assert :ok =
                 MOQX.publish_object(publisher, track, %MOQX.Object{
                   group_id: 7,
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
                            group_id: 7,
                            subgroup_id: 0,
                            object_id: 0,
                            payload: ^payload
                          }
                        }},
                       10_000

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubgroupEnded{
                          subscription: ^subscription,
                          group_id: 7,
                          subgroup_id: 0,
                          outcome: :complete,
                          end_of_group?: true
                        }},
                       10_000
      after
        _result = MOQX.close(subscriber)
      end
    after
      _result = MOQX.close(publisher)
    end
  end

  defp connect(relay) do
    MOQX.connect(relay, protocol: :draft_18, timeout: 10_000)
  end
end
