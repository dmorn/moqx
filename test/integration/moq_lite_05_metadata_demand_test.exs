defmodule MOQX.Integration.MOQLite05MetadataDemandTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :curley_moq_lite_05

  test "absent track provisioning remains separate from controlled admission through the pinned relay" do
    {publisher, subscriber, publication, namespace} = clients([])
    track_ref = %MOQX.TrackRef{namespace: namespace, track: "reactive"}
    {:ok, subscription} = MOQX.subscribe(subscriber, track_ref)

    assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationTrackRequested{request: metadata}},
                   5_000

    assert metadata.track == track_ref

    {:ok, track} =
      MOQX.add_track(publisher, publication, "reactive",
        timescale: 90_000,
        publisher_priority: 17,
        publisher_max_latency: 1_000
      )

    assert_receive {:moqx, ^publisher,
                    %MOQX.Event.PublicationTrackRequestDone{
                      request: ^metadata,
                      reason: :registered
                    }},
                   5_000

    assert_receive {:moqx, ^publisher,
                    %MOQX.Event.PublicationSubscriptionRequested{request: admission}},
                   5_000

    refute_receive {:moqx, ^publisher, %MOQX.Event.PublicationSubscriberJoined{}}, 20
    {:ok, published_subscription} = MOQX.accept_subscription(publisher, admission, track)

    assert :ok =
             MOQX.publish_object(publisher, track, %MOQX.Object{
               group_id: 0,
               object_id: 0,
               timestamp: 180_000,
               payload: "provisioned",
               end_of_group?: true
             })

    assert :ok = MOQX.finish_subscription(publisher, published_subscription)

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.SubscriptionAccepted{
                      subscription: ^subscription,
                      track_info: info
                    }},
                   5_000

    assert info.timescale == 90_000
    assert info.publisher_priority == 17
    assert info.publisher_max_latency == 1_000

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.ObjectReceived{
                      object: %{
                        subscription: ^subscription,
                        payload: "provisioned",
                        timestamp: 180_000
                      }
                    }},
                   5_000

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.SubscriptionDone{subscription: ^subscription}},
                   5_000
  end

  test "explicit metadata rejection terminates the requesting subscriber through the pinned relay" do
    {publisher, subscriber, _publication, namespace} = clients([])

    {:ok, subscription} =
      MOQX.subscribe(subscriber, %MOQX.TrackRef{namespace: namespace, track: "rejected"})

    assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationTrackRequested{request: request}},
                   5_000

    assert :ok =
             MOQX.reject_track_request(publisher, request, %MOQX.SubscriptionRejection{
               code: :unauthorized
             })

    assert_receive {:moqx, ^publisher,
                    %MOQX.Event.PublicationTrackRequestDone{request: ^request, reason: :rejected}},
                   5_000

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.SubscriptionFailed{subscription: ^subscription}},
                   5_000
  end

  test "metadata timeout terminates the requesting subscriber through the pinned relay" do
    {publisher, subscriber, _publication, namespace} = clients(track_metadata_timeout: 50)

    {:ok, subscription} =
      MOQX.subscribe(subscriber, %MOQX.TrackRef{namespace: namespace, track: "expired"})

    assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationTrackRequested{request: request}},
                   5_000

    assert_receive {:moqx, ^publisher,
                    %MOQX.Event.PublicationTrackRequestDone{request: ^request, reason: :timed_out}},
                   5_000

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.SubscriptionFailed{subscription: ^subscription}},
                   5_000
  end

  defp clients(options) do
    endpoint = System.get_env("MOQX_LITE_ENDPOINT", "moql://curley-moq-lite-05-relay:443/")
    ca = System.get_env("MOQX_LITE_CA_FILE", "/certs/ca.pem")

    connection_options = [
      protocol: :moq_lite_05,
      connect_options: [cacertfile: ca],
      timeout: 5_000
    ]

    {:ok, publisher} = MOQX.connect(endpoint, Keyword.put(connection_options, :role, :publisher))

    {:ok, subscriber} =
      MOQX.connect(endpoint, Keyword.put(connection_options, :role, :subscriber))

    on_exit(fn ->
      MOQX.close(subscriber)
      MOQX.close(publisher)
    end)

    namespace = ["metadata-demand", Integer.to_string(System.unique_integer([:positive]))]

    {:ok, publication} =
      MOQX.publish(
        publisher,
        namespace,
        Keyword.merge(
          [missing_track_metadata: :controlled, inbound_subscriptions: :controlled],
          options
        )
      )

    {:ok, discovery} = MOQX.discover(subscriber, Enum.join(namespace, "/"))
    path = Enum.join(namespace, "/")

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.BroadcastAvailable{discovery: ^discovery, path: ^path}},
                   5_000

    {publisher, subscriber, publication, namespace}
  end
end
