defmodule MOQX.Integration.LiteEmptyGroupTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :lite_empty_group
  @timeout 10_000

  test "native relay forwards forward and backward epochs to multiple subscribers and completes after the last empty group" do
    endpoint = System.fetch_env!("MOQX_LITE_ENDPOINT")
    ca = System.fetch_env!("MOQX_LITE_CA_FILE")

    options = [
      protocol: :moq_lite_05,
      timeout: @timeout,
      connect_options: [cacertfile: ca, verify: :verify_peer]
    ]

    {:ok, publisher} = MOQX.connect(endpoint, Keyword.put(options, :role, :publisher))
    {:ok, subscriber} = MOQX.connect(endpoint, Keyword.put(options, :role, :subscriber))

    on_exit(fn ->
      MOQX.close(subscriber)
      MOQX.close(publisher)
    end)

    namespace = ["anon", "empty-epoch-#{System.system_time(:microsecond)}"]
    {:ok, publication} = MOQX.publish(publisher, namespace)
    {:ok, track} = MOQX.add_track(publisher, publication, "media", timescale: 1_000_000)
    {:ok, discovery} = MOQX.discover(subscriber, Enum.join(namespace, "/"))

    assert_receive {:moqx, ^subscriber, %MOQX.Event.BroadcastAvailable{discovery: ^discovery}},
                   @timeout

    {:ok, first} = MOQX.subscribe(subscriber, track.track)
    {:ok, second} = MOQX.subscribe(subscriber, track.track)
    assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationSubscriberJoined{}}, @timeout

    for {group, timestamp} <- [{0, 1000}, {2, 2000}, {4, 100}] do
      payload = IO.iodata_to_binary([MOQX.Codec.encode_varint(timestamp), "codec-packet"])

      assert :ok =
               MOQX.publish_object(publisher, track, %MOQX.Object{
                 group_id: group,
                 object_id: 0,
                 timestamp: timestamp,
                 payload: payload,
                 end_of_group?: true
               })

      for sub <- [first, second] do
        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.ObjectReceived{
                          object: %MOQX.Object{
                            subscription: ^sub,
                            group_id: ^group,
                            timestamp: ^timestamp,
                            payload: ^payload
                          }
                        }},
                       @timeout

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubgroupEnded{
                          subscription: ^sub,
                          group_id: ^group,
                          outcome: :complete,
                          object_count: 1
                        }},
                       @timeout
      end

      empty_group = group + 1
      assert :ok = MOQX.publish_empty_group(publisher, track, empty_group)

      for sub <- [first, second] do
        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubgroupEnded{
                          subscription: ^sub,
                          group_id: ^empty_group,
                          outcome: :complete,
                          object_count: 0
                        }},
                       @timeout
      end
    end

    assert :ok = MOQX.unsubscribe(subscriber, second)
    # A timestamp-only legacy frame is a media-end marker, not an empty group.
    payload = MOQX.Codec.encode_varint(200)

    assert :ok =
             MOQX.publish_object(publisher, track, %MOQX.Object{
               group_id: 6,
               object_id: 0,
               timestamp: 200,
               payload: payload,
               end_of_group?: true
             })

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.ObjectReceived{
                      object: %MOQX.Object{
                        subscription: ^first,
                        group_id: 6,
                        payload: ^payload
                      }
                    }},
                   @timeout

    assert :ok = MOQX.publish_empty_group(publisher, track, 7)
    assert :ok = MOQX.withdraw_track(publisher, track)

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.SubgroupEnded{
                      subscription: ^first,
                      group_id: 7,
                      outcome: :complete,
                      object_count: 0
                    }},
                   @timeout

    assert_receive {:moqx, ^subscriber, %MOQX.Event.SubscriptionDone{subscription: ^first}},
                   @timeout

    refute_receive {:moqx, ^subscriber,
                    %MOQX.Event.ObjectReceived{
                      object: %MOQX.Object{subscription: ^second, group_id: 6}
                    }}
  end
end
