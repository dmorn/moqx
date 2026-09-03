defmodule MOQX.Protocol.MOQLite05PublisherTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQLite05
  alias MOQX.Protocol.MOQLite05.Codec

  alias MOQX.Protocol.MOQLite05.Messages.{
    AnnounceBroadcast,
    AnnounceOk,
    AnnounceRequest,
    Subscribe,
    SubscribeUpdate,
    Track
  }

  alias MOQX.Protocol.Transition
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info

  test "declares the public subscriber and publisher surface" do
    capabilities = MOQLite05.capabilities(%MOQLite05.State{})

    assert capabilities.operations ==
             MapSet.new([
               :subscribe,
               :update_subscription,
               :publish,
               :add_track,
               :accept_publication_subscription,
               :publish_object,
               :finish_published_subscription,
               :finish_publication
             ])

    assert capabilities.delivery_modes == MapSet.new([:subgroup])
  end

  test "rejects unknown published-track options explicitly" do
    {state, publication, _track} = published_track_state(:automatic)

    assert {:error, {:unsupported_published_track_option, :foo, :bar}, %Transition{}} =
             MOQLite05.handle_operation(
               state,
               %MOQX.Operation.AddTrack{
                 publication: publication,
                 track: "other",
                 options: [timescale: 90_000, foo: :bar]
               }
             )
  end

  test "answers a peer Track Stream from a registered public track" do
    state = %MOQLite05.State{phase: :ready, role: :publisher}

    assert {:ok,
            %Transition{
              state: state,
              events: [
                {:publication_started, publication},
                %MOQX.Event.PublicationReady{publication: publication}
              ]
            }} =
             MOQLite05.handle_operation(
               state,
               %MOQX.Operation.Publish{namespace: ["live"], options: []}
             )

    assert {:ok,
            %Transition{
              state: state,
              events: [{:track_added, published_track}]
            }} =
             MOQLite05.handle_operation(
               state,
               %MOQX.Operation.AddTrack{
                 publication: publication,
                 track: "video",
                 options: [
                   timescale: 90_000,
                   publisher_priority: 17,
                   publisher_max_latency: 1_000
                 ]
               }
             )

    assert MOQX.PublishedTrack.track_ref(published_track) ==
             %MOQX.TrackRef{namespace: ["live"], track: "video"}

    stream = peer_bidirectional_stream(4)

    request =
      <<6, Codec.encode_track(%Track{broadcast_path: "live", track_name: "video"})::binary>>

    assert {:ok,
            %Transition{
              actions: [
                {:send_stream, {:peer_stream, 4},
                 <<8, 17, 0, 0x43, 0xE8, 0x80, 0x01, 0x5F, 0x90>>, [finish: true]}
              ]
            }} = MOQLite05.handle_transport(state, {:stream_data, stream, request, %{}})

    missing =
      <<6, Codec.encode_track(%Track{broadcast_path: "live", track_name: "missing"})::binary>>

    assert {:ok,
            %Transition{
              actions: [{:abort_stream_sending, {:peer_stream, 6}, 16}]
            }} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, peer_bidirectional_stream(6), missing, %{}}
             )
  end

  test "exposes a controlled peer Subscribe Stream through an opaque public request" do
    {state, publication, published_track} = published_track_state(:controlled)
    stream = peer_bidirectional_stream(8)

    subscribe = %Subscribe{
      subscribe_id: 42,
      broadcast_path: "live",
      track_name: "video",
      subscriber_priority: 9,
      subscriber_ordered: true,
      subscriber_max_latency: 250,
      group_start: 7,
      group_end: 11
    }

    request_bytes = <<2, Codec.encode_subscribe(subscribe)::binary>>

    assert {:ok,
            %Transition{
              state: pending,
              events: [
                %MOQX.Event.PublicationSubscriptionRequested{
                  request:
                    %MOQX.PublicationSubscriptionRequest{
                      publication: ^publication,
                      track: %MOQX.TrackRef{namespace: ["live"], track: "video"},
                      subscriber_priority: 9,
                      group_order: :ascending,
                      forward: true,
                      filter: %MOQX.SubscriptionFilter{
                        type: :absolute_range,
                        start_location: {7, 0},
                        end_group: 11
                      }
                    } = request
                }
              ],
              actions: [
                {:start_timer, {:publisher_subscription_decision, handle}, 500}
              ]
            }} = MOQLite05.handle_transport(state, {:stream_data, stream, request_bytes, %{}})

    assert request.handle == handle
    assert inspect(handle) == "#MOQX.PublicationSubscriptionRequest.Handle<OPAQUE>"

    assert {:ok,
            %Transition{
              state: accepted,
              events: [
                {:published_subscription_accepted, published_subscription},
                %MOQX.Event.PublicationSubscriberJoined{
                  track: ^published_track,
                  subscription: published_subscription,
                  request_id: 42
                }
              ],
              actions: [
                {:cancel_timer, {:publisher_subscription_decision, ^handle}}
              ]
            }} =
             MOQLite05.handle_operation(
               pending,
               %MOQX.Operation.AcceptPublicationSubscription{
                 request: request,
                 published_track: published_track
               }
             )

    update = %MOQX.Protocol.MOQLite05.Messages.SubscribeUpdate{
      subscriber_priority: 10,
      subscriber_ordered: false,
      subscriber_max_latency: 100,
      group_start: 7,
      group_end: 11
    }

    later_update = %{update | subscriber_priority: 11}

    assert {:ok,
            %Transition{
              state: updated,
              events: []
            }} =
             MOQLite05.handle_transport(
               accepted,
               {:stream_data, stream,
                Codec.encode_subscribe_update(update) <>
                  Codec.encode_subscribe_update(later_update), %{}}
             )

    assert updated.publisher_subscriptions[42].subscribe.subscriber_priority == 11
    assert updated.publisher_subscriptions[42].subscribe.subscriber_ordered == false
    accepted = updated

    object = %MOQX.Object{
      group_id: 7,
      object_id: 0,
      timestamp: 90_000,
      end_of_group?: true,
      payload: "x"
    }

    assert {:ok,
            %Transition{
              state: published,
              events: [{:object_published, ^published_track}],
              actions: [
                {:send_stream, {:peer_stream, 8}, <<0, 1, 7>>, []},
                {:open_stream, {:group, 42, 7}, [direction: :unidirectional],
                 <<0, 2, 42, 7, 0x80, 0x02, 0xBF, 0x20, 1, "x">>, [finish: true]}
              ]
            }} =
             MOQLite05.handle_operation(
               accepted,
               %MOQX.Operation.PublishObject{track: published_track, object: object}
             )

    later = %{object | group_id: 9, timestamp: 180_000}

    assert {:ok,
            %Transition{
              state: published,
              actions: [
                {:send_stream, {:peer_stream, 8}, <<2, 3, 8, 8, 0>>, []},
                {:open_stream, {:group, 42, 9}, [direction: :unidirectional], _group,
                 [finish: true]}
              ]
            }} =
             MOQLite05.handle_operation(
               published,
               %MOQX.Operation.PublishObject{track: published_track, object: later}
             )

    assert {:ok,
            %Transition{
              events: [
                {:published_subscription_finished, ^published_subscription},
                %MOQX.Event.PublicationSubscriberLeft{
                  track: ^published_track,
                  subscription: ^published_subscription,
                  request_id: 42
                }
              ],
              actions: [
                {:send_stream, {:peer_stream, 8}, <<1, 1, 9>>, [finish: true]}
              ]
            }} =
             MOQLite05.handle_operation(
               published,
               %MOQX.Operation.FinishPublishedSubscription{
                 subscription: published_subscription
               }
             )
  end

  test "applies a SUBSCRIBE_UPDATE coalesced with the initial controlled SUBSCRIBE" do
    {state, _publication, _published_track} = published_track_state(:controlled)
    stream = peer_bidirectional_stream(10)

    subscribe = %Subscribe{
      subscribe_id: 43,
      broadcast_path: "live",
      track_name: "video",
      subscriber_priority: 9,
      group_start: 7
    }

    update = %SubscribeUpdate{
      subscriber_priority: 11,
      subscriber_ordered: true,
      subscriber_max_latency: 100,
      group_start: 8,
      group_end: 12
    }

    bytes =
      <<2, Codec.encode_subscribe(subscribe)::binary,
        Codec.encode_subscribe_update(update)::binary>>

    assert {:ok,
            %Transition{
              state: %{pending_publisher_subscriptions: %{43 => pending}}
            }} = MOQLite05.handle_transport(state, {:stream_data, stream, bytes, %{}})

    assert pending.subscribe.subscriber_priority == 11
    assert pending.subscribe.subscriber_ordered
    assert pending.subscribe.group_start == 8
    assert pending.subscribe.group_end == 12
  end

  test "resets an unsupported bidirectional request without failing the connection" do
    assert {:ok, %Transition{actions: [{:abort_stream_sending, {:peer_stream, 12}, 2}]}} =
             MOQLite05.handle_transport(
               %MOQLite05.State{phase: :ready},
               {:stream_data, peer_bidirectional_stream(12), <<0x21, 0>>, %{}}
             )
  end

  test "resets an inbound subscription for an unavailable publication" do
    subscribe = %Subscribe{
      subscribe_id: 44,
      broadcast_path: "missing",
      track_name: "video",
      subscriber_priority: 9
    }

    assert {:ok, %Transition{actions: [{:abort_stream_sending, {:peer_stream, 14}, 0x10}]}} =
             MOQLite05.handle_transport(
               %MOQLite05.State{phase: :ready, role: :publisher},
               {:stream_data, peer_bidirectional_stream(14),
                <<2, Codec.encode_subscribe(subscribe)::binary>>, %{}}
             )
  end

  test "tracks two subscribers and releases each exactly once" do
    {state, _publication, published_track} = published_track_state(:controlled)
    {state, first} = accept_subscription(state, published_track, 1, 8)
    {state, second} = accept_subscription(state, published_track, 2, 12)

    object = %MOQX.Object{
      group_id: 7,
      object_id: 0,
      timestamp: 90_000,
      end_of_group?: true,
      payload: "x"
    }

    assert {:ok,
            %Transition{
              state: state,
              actions: [first_ok, first_action, second_ok, second_action]
            }} =
             MOQLite05.handle_operation(
               state,
               %MOQX.Operation.PublishObject{track: published_track, object: object}
             )

    assert {:send_stream, {:peer_stream, 8}, <<0, 1, 7>>, []} = first_ok
    assert {:send_stream, {:peer_stream, 12}, <<0, 1, 7>>, []} = second_ok
    assert {:open_stream, {:group, 1, 7}, _, _, [finish: true]} = first_action
    assert {:open_stream, {:group, 2, 7}, _, _, [finish: true]} = second_action

    assert {:ok,
            %Transition{
              state: state,
              events: [
                %MOQX.Event.PublicationSubscriberLeft{
                  track: ^published_track,
                  subscription: ^first,
                  request_id: 1
                }
              ],
              actions: [{:send_stream, {:peer_stream, 8}, <<>>, [finish: true]}]
            }} =
             MOQLite05.handle_transport(
               state,
               {:stream_event, peer_bidirectional_stream(8), :peer_finished_sending, %{}}
             )

    assert map_size(state.publisher_subscriptions) == 1

    assert {:ok,
            %Transition{
              state: finished,
              events: [
                %MOQX.Event.PublicationSubscriberLeft{
                  track: ^published_track,
                  subscription: ^second,
                  request_id: 2
                }
              ]
            }} =
             MOQLite05.handle_transport(
               state,
               {:stream_event, peer_bidirectional_stream(12), :peer_aborted_sending,
                %{error_code: 7}}
             )

    assert finished.publisher_subscriptions == %{}

    assert {:ok, %Transition{state: ^finished, events: []}} =
             MOQLite05.handle_transport(
               finished,
               {:stream_event, peer_bidirectional_stream(12), :peer_aborted_sending,
                %{error_code: 7}}
             )
  end

  test "advertises and withdraws a publication on a peer Announce Stream" do
    {state, publication, _published_track} = published_track_state(:automatic)
    stream = peer_bidirectional_stream(16)
    announce = %AnnounceRequest{broadcast_path_prefix: "", exclude_hop: 0}
    bytes = <<1, Codec.encode_announce_request(announce)::binary>>

    expected =
      Codec.encode_announce_ok(%AnnounceOk{hop_id: 0, active_count: 1}) <>
        Codec.encode_announce_broadcast(%AnnounceBroadcast{
          status: :active,
          path_suffix: "live",
          hop_ids: []
        })

    assert {:ok,
            %Transition{
              state: announced,
              actions: [{:send_stream, {:peer_stream, 16}, ^expected, []}]
            }} = MOQLite05.handle_transport(state, {:stream_data, stream, bytes, %{}})

    ended =
      Codec.encode_announce_broadcast(%AnnounceBroadcast{
        status: :ended,
        path_suffix: "live",
        hop_ids: []
      })

    assert {:ok,
            %Transition{
              state: %{publications: %{}},
              events: [{:publication_finished, ^publication}],
              actions: [{:send_stream, {:peer_stream, 16}, ^ended, []}]
            }} =
             MOQLite05.handle_operation(
               announced,
               %MOQX.Operation.FinishPublication{publication: publication}
             )
  end

  test "reactively registers and accepts a requested track" do
    state = %MOQLite05.State{phase: :ready, role: :publisher, handle_scope: make_ref()}

    {:ok, published} =
      MOQLite05.handle_operation(state, %MOQX.Operation.Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    {:publication_started, publication} = List.first(published.events)
    stream = peer_bidirectional_stream(20)

    subscribe = %Subscribe{
      subscribe_id: 9,
      broadcast_path: "live",
      track_name: "audio",
      subscriber_priority: 20,
      group_start: 3
    }

    bytes = <<2, Codec.encode_subscribe(subscribe)::binary>>

    {:ok, pending} =
      MOQLite05.handle_transport(published.state, {:stream_data, stream, bytes, %{}})

    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events

    assert {:ok,
            %Transition{
              state: accepted,
              events: [
                {:reactive_subscription_accepted, track, subscription},
                %MOQX.Event.PublicationSubscriberJoined{
                  track: track,
                  subscription: subscription,
                  request_id: 9
                }
              ],
              actions: [
                {:cancel_timer, {:publisher_subscription_decision, handle}}
              ]
            }} =
             MOQLite05.handle_operation(
               pending.state,
               %MOQX.Operation.AcceptPublicationSubscription{
                 request: request,
                 published_track: nil,
                 reply_mode: :reactive,
                 options: [timescale: 48_000]
               }
             )

    assert request.handle == handle
    assert MOQX.PublishedTrack.track_ref(track) == request.track
    assert accepted.publications[publication.id].tracks["audio"].timescale == 48_000
  end

  test "rejects a controlled request by resetting its stream once" do
    {state, _publication, _track} = published_track_state(:controlled)

    subscribe = %Subscribe{
      subscribe_id: 33,
      broadcast_path: "live",
      track_name: "missing",
      subscriber_priority: 9,
      group_start: 1
    }

    stream = peer_bidirectional_stream(28)
    bytes = <<2, Codec.encode_subscribe(subscribe)::binary>>
    {:ok, pending} = MOQLite05.handle_transport(state, {:stream_data, stream, bytes, %{}})
    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events

    assert {:ok,
            %Transition{
              state: %{pending_publisher_subscriptions: %{}},
              events: [
                %MOQX.Event.PublicationSubscriptionCancelled{
                  request: ^request,
                  reason: :decision_timeout
                }
              ],
              actions: [{:abort_stream_sending, {:peer_stream, 28}, 2}]
            }} =
             MOQLite05.handle_transport(
               pending.state,
               {:runtime_timeout, {:publisher_subscription_decision, request.handle}}
             )

    assert {:ok,
            %Transition{
              state: %{pending_publisher_subscriptions: %{}},
              actions: [
                {:cancel_timer, {:publisher_subscription_decision, handle}},
                {:abort_stream_sending, {:peer_stream, 28}, 16}
              ]
            }} =
             MOQLite05.handle_operation(
               pending.state,
               %MOQX.Operation.RejectPublicationSubscription{
                 request: request,
                 rejection: %MOQX.SubscriptionRejection{code: :track_does_not_exist}
               }
             )

    assert request.handle == handle
  end

  test "finishing a publication deterministically ends active demand" do
    {state, publication, published_track} = published_track_state(:controlled)
    {state, subscription} = accept_subscription(state, published_track, 5, 24)

    object = %MOQX.Object{
      group_id: 7,
      object_id: 0,
      timestamp: 1,
      end_of_group?: true,
      payload: "x"
    }

    {:ok, published} =
      MOQLite05.handle_operation(state, %MOQX.Operation.PublishObject{
        track: published_track,
        object: object
      })

    assert {:ok,
            %Transition{
              state: %{
                publications: %{},
                publisher_subscriptions: %{},
                pending_publisher_subscriptions: %{}
              },
              events: [
                %MOQX.Event.PublicationSubscriberLeft{
                  track: ^published_track,
                  subscription: ^subscription,
                  request_id: 5
                },
                {:publication_finished, ^publication}
              ],
              actions: [
                {:send_stream, {:peer_stream, 24}, <<1, 1, 7>>, [finish: true]}
              ]
            }} =
             MOQLite05.handle_operation(
               published.state,
               %MOQX.Operation.FinishPublication{publication: publication}
             )
  end

  test "connection closure releases every active subscriber handle" do
    {state, _publication, published_track} = published_track_state(:controlled)
    {state, first} = accept_subscription(state, published_track, 1, 8)
    {state, second} = accept_subscription(state, published_track, 2, 12)

    assert {:ok,
            %Transition{
              state: %{publisher_subscriptions: %{}, pending_publisher_subscriptions: %{}},
              events: [
                %MOQX.Event.PublicationSubscriberLeft{
                  subscription: ^first,
                  request_id: 1
                },
                %MOQX.Event.PublicationSubscriberLeft{
                  subscription: ^second,
                  request_id: 2
                },
                %MOQX.Event.ConnectionClosed{metadata: %{error_code: 9}}
              ]
            }} =
             MOQLite05.handle_transport(
               state,
               {:connection_event, :conn, :closed, %{error_code: 9}}
             )
  end

  defp published_track_state(inbound_subscriptions) do
    state = %MOQLite05.State{phase: :ready, role: :publisher, handle_scope: make_ref()}

    {:ok, published} =
      MOQLite05.handle_operation(state, %MOQX.Operation.Publish{
        namespace: ["live"],
        options: [
          inbound_subscriptions: inbound_subscriptions,
          subscription_decision_timeout: 500
        ]
      })

    {:publication_started, publication} = List.first(published.events)

    {:ok, added} =
      MOQLite05.handle_operation(published.state, %MOQX.Operation.AddTrack{
        publication: publication,
        track: "video",
        options: [timescale: 90_000]
      })

    {:track_added, published_track} = List.first(added.events)
    {added.state, publication, published_track}
  end

  defp accept_subscription(state, published_track, subscribe_id, stream_id) do
    subscribe = %Subscribe{
      subscribe_id: subscribe_id,
      broadcast_path: "live",
      track_name: "video",
      subscriber_priority: 9,
      group_start: 7
    }

    stream = peer_bidirectional_stream(stream_id)
    bytes = <<2, Codec.encode_subscribe(subscribe)::binary>>
    {:ok, pending} = MOQLite05.handle_transport(state, {:stream_data, stream, bytes, %{}})
    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events

    {:ok, accepted} =
      MOQLite05.handle_operation(pending.state, %MOQX.Operation.AcceptPublicationSubscription{
        request: request,
        published_track: published_track
      })

    [{:published_subscription_accepted, subscription}, _joined] = accepted.events
    {accepted.state, subscription}
  end

  defp peer_bidirectional_stream(stream_id) do
    %Stream{
      info: %Info{
        stream_id: stream_id,
        direction: :bidirectional,
        initiator: :peer,
        initiator_role: :client,
        local_role: :server,
        send_side?: true,
        receive_side?: true
      }
    }
  end
end
