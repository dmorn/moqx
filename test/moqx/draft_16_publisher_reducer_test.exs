defmodule MOQX.Draft16PublisherReducerTest do
  use ExUnit.Case, async: true

  alias MOQX.Event.{
    PublicationSubscriberJoined,
    PublicationSubscriberLeft,
    PublicationSubscriptionCancelled,
    PublicationSubscriptionRequested
  }

  alias MOQX.Operation.{
    AcceptPublicationSubscription,
    AddTrack,
    FinishPublication,
    Publish,
    PublishObject,
    RejectPublicationSubscription
  }

  alias MOQX.Protocol.Draft16
  alias MOQX.Protocol.Draft16.State
  alias MOQX.Protocol.MOQTDraft16.Codec
  alias MOQX.Protocol.Transition
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info

  test "namespace and track have independent draft-16 readiness boundaries" do
    ready = %State{phase: :ready, max_request_id: 4}

    assert {:ok,
            %Transition{
              state: namespace_pending,
              events: [{:publication_started, publication}],
              actions: [{:send_stream, :control, publish_namespace, []}]
            }} =
             Draft16.handle_operation(ready, %Publish{namespace: ["live", "camera"]})

    assert publish_namespace ==
             <<0x06, 0, 15, 0, 2, 4, "live", 6, "camera", 0>>

    assert {:ok,
            %Transition{
              state: namespace_ready,
              events: [%MOQX.Event.PublicationReady{publication: ^publication}]
            }} =
             Draft16.handle_transport(
               namespace_pending,
               {:stream_data, control_stream(), <<0x07, 0, 2, 0, 0>>, %{}}
             )

    assert {:ok,
            %Transition{
              state: track_pending,
              events: [{:track_added, track}],
              actions: [{:send_stream, :control, publish_track, []}]
            }} =
             Draft16.handle_operation(namespace_ready, %AddTrack{
               publication: publication,
               track: "video"
             })

    assert publish_track ==
             <<0x1D, 0, 25, 2, 2, 4, "live", 6, "camera", 5, "video", 0, 1, 0x10, 1, 0>>

    object = %MOQX.Object{
      group_id: 7,
      subgroup_id: 3,
      object_id: 0,
      publisher_priority: 10,
      payload: "fragment"
    }

    assert {:error, :published_track_not_ready, %Transition{actions: []}} =
             Draft16.handle_operation(track_pending, %PublishObject{
               track: track,
               object: object
             })

    assert {:ok,
            %Transition{
              state: track_ready,
              events: [
                %MOQX.Event.PublicationSubscriberJoined{
                  track: ^track,
                  request_id: 2
                }
              ]
            }} =
             Draft16.handle_transport(
               track_pending,
               {:stream_data, control_stream(), <<0x1E, 0, 2, 2, 0>>, %{}}
             )

    assert {:ok,
            %Transition{
              events: [{:object_published, ^track}],
              actions: [
                {:open_stream, {:publication, 2, 0}, [direction: :unidirectional], subgroup,
                 [finish: true]}
              ]
            }} =
             Draft16.handle_operation(track_ready, %PublishObject{
               track: track,
               object: object
             })

    assert subgroup == <<0x14, 0, 7, 3, 10, 0, 8, "fragment">>
  end

  test "a datagram track publishes without opening a stream and completes with zero streams" do
    ready = %State{phase: :ready, max_request_id: 4}
    {:ok, published} = Draft16.handle_operation(ready, %Publish{namespace: ["live"]})
    {:publication_started, publication} = List.first(published.events)

    {:ok, namespace_ready} =
      Draft16.handle_transport(
        published.state,
        {:stream_data, control_stream(), <<0x07, 0, 2, 0, 0>>, %{}}
      )

    {:ok, added} =
      Draft16.handle_operation(namespace_ready.state, %AddTrack{
        publication: publication,
        track: "audio",
        options: [delivery: :datagram]
      })

    {:track_added, track} = List.first(added.events)

    {:ok, track_ready} =
      Draft16.handle_transport(
        added.state,
        {:stream_data, control_stream(), <<0x1E, 0, 2, 2, 0>>, %{}}
      )

    object = %MOQX.Object{
      group_id: 9,
      object_id: 0,
      publisher_priority: 17,
      end_of_group?: true,
      payload: "media"
    }

    assert {:ok,
            %Transition{
              state: delivered,
              actions: [{:send_datagram, <<0x06, 0, 9, 17, "media">>}]
            }} =
             Draft16.handle_operation(track_ready.state, %PublishObject{
               track: track,
               object: object
             })

    assert {:ok,
            %Transition{
              actions: [
                {:send_stream, :control, publish_done, []},
                {:send_stream, :control, _namespace_done, []}
              ]
            }} =
             Draft16.handle_operation(delivered, %FinishPublication{
               publication: publication
             })

    assert {:ok, [{0x0B, publish_done_payload}], ""} = Codec.decode_control(publish_done)

    assert {:ok, %{request_id: 2, stream_count: 0}} =
             Codec.decode_publish_done(publish_done_payload)
  end

  test "rejects an unknown publication delivery mode" do
    ready = %State{phase: :ready, max_request_id: 4}
    {:ok, published} = Draft16.handle_operation(ready, %Publish{namespace: ["live"]})
    {:publication_started, publication} = List.first(published.events)

    {:ok, namespace_ready} =
      Draft16.handle_transport(
        published.state,
        {:stream_data, control_stream(), <<0x07, 0, 2, 0, 0>>, %{}}
      )

    assert {:error, :invalid_publication_delivery, %Transition{}} =
             Draft16.handle_operation(namespace_ready.state, %AddTrack{
               publication: publication,
               track: "audio",
               options: [delivery: :unknown]
             })
  end

  test "namespace rejection emits a typed error and invalidates the publication handle" do
    ready = %State{phase: :ready, max_request_id: 2}

    {:ok,
     %Transition{
       state: pending,
       events: [{:publication_started, publication}]
     }} = Draft16.handle_operation(ready, %Publish{namespace: ["denied"]})

    request_error = <<0x05, 0, 10, 0, 1, 0, 6, "denied">>

    assert {:ok,
            %Transition{
              state: rejected,
              events: [
                %MOQX.Event.PublicationFailed{
                  publication: ^publication,
                  error: %MOQX.ProtocolError{
                    protocol: :draft_16,
                    operation: :publish,
                    code: 1,
                    reason: "denied"
                  }
                }
              ]
            }} =
             Draft16.handle_transport(
               pending,
               {:stream_data, control_stream(), request_error, %{}}
             )

    assert rejected.publications == %{}

    assert {:error, :unknown_publication, %Transition{state: ^rejected}} =
             Draft16.handle_operation(rejected, %AddTrack{
               publication: publication,
               track: "video"
             })
  end

  test "track rejection preserves the ready namespace and invalidates only that track" do
    ready = %State{phase: :ready, max_request_id: 4}

    {:ok, published} =
      Draft16.handle_operation(ready, %Publish{namespace: ["live"]})

    {:publication_started, publication} = List.first(published.events)

    {:ok, namespace_ready} =
      Draft16.handle_transport(
        published.state,
        {:stream_data, control_stream(), <<0x07, 0, 2, 0, 0>>, %{}}
      )

    {:ok, added} =
      Draft16.handle_operation(namespace_ready.state, %AddTrack{
        publication: publication,
        track: "video"
      })

    {:track_added, track} = List.first(added.events)
    request_error = <<0x05, 0, 13, 2, 0x19, 0, 9, "duplicate">>

    assert {:ok,
            %Transition{
              state: rejected,
              events: [
                %MOQX.Event.PublicationTrackFailed{
                  track: ^track,
                  error: %MOQX.ProtocolError{
                    protocol: :draft_16,
                    operation: :add_track,
                    code: 0x19,
                    reason: "duplicate"
                  }
                }
              ]
            }} =
             Draft16.handle_transport(
               added.state,
               {:stream_data, control_stream(), request_error, %{}}
             )

    assert rejected.publications[publication.id].status == :ready
    assert rejected.publications[publication.id].tracks == %{}

    assert {:error, :unknown_published_track, %Transition{}} =
             Draft16.handle_operation(rejected, %PublishObject{
               track: track,
               object: %MOQX.Object{group_id: 0, object_id: 0, payload: "x"}
             })
  end

  test "relay namespace cancellation drops the complete publication scope" do
    ready = %State{phase: :ready, max_request_id: 4}
    {:ok, published} = Draft16.handle_operation(ready, %Publish{namespace: ["live"]})
    {:publication_started, publication} = List.first(published.events)

    {:ok, namespace_ready} =
      Draft16.handle_transport(
        published.state,
        {:stream_data, control_stream(), <<0x07, 0, 2, 0, 0>>, %{}}
      )

    {:ok, added} =
      Draft16.handle_operation(namespace_ready.state, %AddTrack{
        publication: publication,
        track: "video"
      })

    cancel = <<0x0C, 0, 10, 0, 1, 7, "expired">>

    assert {:ok,
            %Transition{
              state: cancelled,
              events: [
                %MOQX.Event.PublicationCancelled{
                  publication: ^publication,
                  error: %MOQX.ProtocolError{
                    protocol: :draft_16,
                    operation: :publish,
                    code: 1,
                    reason: "expired"
                  }
                }
              ]
            }} =
             Draft16.handle_transport(
               added.state,
               {:stream_data, control_stream(), cancel, %{}}
             )

    assert cancelled.publications == %{}
  end

  test "finish sends per-track completion before namespace withdrawal and drops all handles" do
    ready = %State{phase: :ready, max_request_id: 4}
    {:ok, published} = Draft16.handle_operation(ready, %Publish{namespace: ["live"]})
    {:publication_started, publication} = List.first(published.events)

    {:ok, namespace_ready} =
      Draft16.handle_transport(
        published.state,
        {:stream_data, control_stream(), <<0x07, 0, 2, 0, 0>>, %{}}
      )

    {:ok, added} =
      Draft16.handle_operation(namespace_ready.state, %AddTrack{
        publication: publication,
        track: "video"
      })

    {:track_added, track} = List.first(added.events)

    {:ok, track_ready} =
      Draft16.handle_transport(
        added.state,
        {:stream_data, control_stream(), <<0x1E, 0, 2, 2, 0>>, %{}}
      )

    {:ok, object_published} =
      Draft16.handle_operation(track_ready.state, %PublishObject{
        track: track,
        object: %MOQX.Object{group_id: 0, object_id: 0, payload: "x"}
      })

    publish_done = <<0x0B, 0, 12, 2, 2, 1, 8, "complete">>
    namespace_done = <<0x09, 0, 1, 0>>

    assert {:ok,
            %Transition{
              state: finished,
              events: [
                {:publication_finished, ^publication},
                %MOQX.Event.PublicationSubscriberLeft{track: ^track, request_id: 2}
              ],
              actions: [
                {:send_stream, :control, ^publish_done, []},
                {:send_stream, :control, ^namespace_done, []}
              ]
            }} =
             Draft16.handle_operation(object_published.state, %FinishPublication{
               publication: publication,
               options: [status: 2, reason: "complete"]
             })

    assert finished.publications == %{}

    assert {:error, :unknown_publication, %Transition{}} =
             Draft16.handle_operation(finished, %FinishPublication{publication: publication})
  end

  test "controlled inbound subscribe is accepted through protocol-neutral handles" do
    scope = make_ref()
    ready = %State{phase: :ready, max_request_id: 4, handle_scope: scope}

    {:ok, published} =
      Draft16.handle_operation(ready, %Publish{
        namespace: ["live"],
        options: [
          inbound_subscriptions: :controlled,
          subscription_decision_timeout: 250,
          max_pending_subscriptions: 2
        ]
      })

    {:publication_started, publication} = List.first(published.events)

    {:ok, namespace_ready} =
      Draft16.handle_transport(
        published.state,
        {:stream_data, control_stream(), <<0x07, 0, 2, 0, 0>>, %{}}
      )

    {:ok, added} =
      Draft16.handle_operation(namespace_ready.state, %AddTrack{
        publication: publication,
        track: "video"
      })

    {:track_added, track} = List.first(added.events)

    subscribe =
      Codec.subscribe(
        1,
        %MOQX.TrackRef{namespace: ["live"], track: "video"},
        priority: 9,
        group_order: :ascending
      )

    assert {:ok,
            %Transition{
              state: pending,
              events: [
                %PublicationSubscriptionRequested{
                  request:
                    %MOQX.PublicationSubscriptionRequest{
                      publication: ^publication,
                      track: %MOQX.TrackRef{namespace: ["live"], track: "video"},
                      subscriber_priority: 9,
                      group_order: :ascending,
                      forward: true,
                      filter: %MOQX.SubscriptionFilter{type: :largest_object}
                    } = request
                }
              ],
              actions: [
                {:start_timer, {:publisher_subscription_decision, handle}, 250}
              ]
            }} =
             Draft16.handle_transport(
               added.state,
               {:stream_data, control_stream(), subscribe, %{}}
             )

    assert request.handle == handle
    assert inspect(handle) == "#MOQX.PublicationSubscriptionRequest.Handle<OPAQUE>"

    subscribe_ok =
      Codec.subscribe_ok(1, 1,
        group_order: :ascending,
        forward: true
      )

    assert {:ok,
            %Transition{
              state: accepted,
              events: [
                %PublicationSubscriberJoined{track: ^track, request_id: 1}
              ],
              actions: [
                {:cancel_timer, {:publisher_subscription_decision, ^handle}},
                {:send_stream, :control, ^subscribe_ok, []}
              ]
            }} =
             Draft16.handle_operation(pending, %AcceptPublicationSubscription{
               request: request,
               published_track: track
             })

    assert accepted.pending_publisher_subscriptions == %{}
    assert accepted.publisher_subscriptions[1].track == track

    {:ok, primary_ready} =
      Draft16.handle_transport(
        accepted,
        {:stream_data, control_stream(), <<0x1E, 0, 2, 2, 0>>, %{}}
      )

    object = %MOQX.Object{group_id: 7, object_id: 0, payload: "x"}
    primary_bytes = Codec.encode_subgroup(0, object)
    inbound_bytes = Codec.encode_subgroup(1, object)

    assert {:ok,
            %Transition{
              state: delivered,
              actions: [
                {:open_stream, {:publication, 2, 0}, [direction: :unidirectional], ^primary_bytes,
                 [finish: true]},
                {:open_stream, {:publication, 1, 1}, [direction: :unidirectional], ^inbound_bytes,
                 [finish: true]}
              ]
            }} =
             Draft16.handle_operation(primary_ready.state, %PublishObject{
               track: track,
               object: object
             })

    unsubscribe = Codec.unsubscribe(1)
    publish_done = Codec.publish_done(1, 3, 1, "subscription ended")

    assert {:ok,
            %Transition{
              state: unsubscribed,
              events: [
                %PublicationSubscriberLeft{track: ^track, request_id: 1}
              ],
              actions: [{:send_stream, :control, ^publish_done, []}]
            }} =
             Draft16.handle_transport(
               delivered,
               {:stream_data, control_stream(), unsubscribe, %{}}
             )

    assert unsubscribed.publisher_subscriptions == %{}

    second_subscribe =
      Codec.subscribe(
        3,
        %MOQX.TrackRef{namespace: ["live"], track: "video"},
        []
      )

    {:ok, second_pending} =
      Draft16.handle_transport(
        unsubscribed,
        {:stream_data, control_stream(), second_subscribe, %{}}
      )

    %PublicationSubscriptionRequested{request: second_request} =
      List.first(second_pending.events)

    second_handle = second_request.handle

    [
      internal_error: 0,
      unauthorized: 1,
      timeout: 2,
      not_supported: 3,
      malformed_auth_token: 4,
      expired_auth_token: 5,
      track_does_not_exist: 0x10,
      invalid_range: 0x11
    ]
    |> Enum.each(fn {code, wire_code} ->
      expected = Codec.request_error(3, wire_code, Atom.to_string(code))

      assert {:ok,
              %Transition{
                actions: [
                  {:cancel_timer, {:publisher_subscription_decision, ^second_handle}},
                  {:send_stream, :control, ^expected, []}
                ]
              }} =
               Draft16.handle_operation(
                 second_pending.state,
                 %RejectPublicationSubscription{
                   request: second_request,
                   rejection: %MOQX.SubscriptionRejection{code: code}
                 }
               )
    end)

    rejection = %MOQX.SubscriptionRejection{code: :unauthorized, reason: "denied"}
    request_error = Codec.request_error(3, 1, "denied")

    assert {:ok,
            %Transition{
              state: rejected,
              actions: [
                {:cancel_timer, {:publisher_subscription_decision, ^second_handle}},
                {:send_stream, :control, ^request_error, []}
              ]
            }} =
             Draft16.handle_operation(second_pending.state, %RejectPublicationSubscription{
               request: second_request,
               rejection: rejection
             })

    assert rejected.pending_publisher_subscriptions == %{}

    third_subscribe =
      Codec.subscribe(
        5,
        %MOQX.TrackRef{namespace: ["live"], track: "video"},
        []
      )

    {:ok, third_pending} =
      Draft16.handle_transport(
        rejected,
        {:stream_data, control_stream(), third_subscribe, %{}}
      )

    %PublicationSubscriptionRequested{request: third_request} =
      List.first(third_pending.events)

    timeout_error =
      Codec.request_error(
        5,
        2,
        "subscription decision timed out"
      )

    assert {:ok,
            %Transition{
              state: timed_out,
              events: [
                %PublicationSubscriptionCancelled{
                  request: ^third_request,
                  reason: :decision_timeout
                }
              ],
              actions: [{:send_stream, :control, ^timeout_error, []}]
            }} =
             Draft16.handle_transport(
               third_pending.state,
               {:runtime_timeout, {:publisher_subscription_decision, third_request.handle}}
             )

    assert timed_out.pending_publisher_subscriptions == %{}
  end

  test "finishing a publication cancels pending requests and completes active subscribers" do
    scope = make_ref()
    ready = %State{phase: :ready, max_request_id: 4, handle_scope: scope}

    {:ok, published} =
      Draft16.handle_operation(ready, %Publish{
        namespace: ["live"],
        options: [
          inbound_subscriptions: :controlled,
          subscription_decision_timeout: 250
        ]
      })

    {:publication_started, publication} = List.first(published.events)

    {:ok, namespace_ready} =
      Draft16.handle_transport(
        published.state,
        {:stream_data, control_stream(), <<0x07, 0, 2, 0, 0>>, %{}}
      )

    {:ok, added} =
      Draft16.handle_operation(namespace_ready.state, %AddTrack{
        publication: publication,
        track: "video"
      })

    {:track_added, track} = List.first(added.events)

    {:ok, primary_ready} =
      Draft16.handle_transport(
        added.state,
        {:stream_data, control_stream(), <<0x1E, 0, 2, 2, 0>>, %{}}
      )

    subscribe_one =
      Codec.subscribe(1, %MOQX.TrackRef{namespace: ["live"], track: "video"}, [])

    {:ok, first_pending} =
      Draft16.handle_transport(
        primary_ready.state,
        {:stream_data, control_stream(), subscribe_one, %{}}
      )

    %PublicationSubscriptionRequested{request: first_request} =
      List.first(first_pending.events)

    {:ok, first_accepted} =
      Draft16.handle_operation(first_pending.state, %AcceptPublicationSubscription{
        request: first_request,
        published_track: track
      })

    subscribe_two =
      Codec.subscribe(3, %MOQX.TrackRef{namespace: ["live"], track: "video"}, [])

    {:ok, second_pending} =
      Draft16.handle_transport(
        first_accepted.state,
        {:stream_data, control_stream(), subscribe_two, %{}}
      )

    %PublicationSubscriptionRequested{request: second_request} =
      List.first(second_pending.events)

    second_handle = second_request.handle

    {:ok, delivered} =
      Draft16.handle_operation(second_pending.state, %PublishObject{
        track: track,
        object: %MOQX.Object{group_id: 0, object_id: 0, payload: "x"}
      })

    pending_error = Codec.request_error(3, 0x10, "publication finished")
    active_done = Codec.publish_done(1, 2, 1, "complete")
    primary_done = Codec.publish_done(2, 2, 1, "complete")
    namespace_done = Codec.publish_namespace_done(0)

    assert {:ok,
            %Transition{
              state: finished,
              events: [
                {:publication_finished, ^publication},
                %PublicationSubscriptionCancelled{
                  request: ^second_request,
                  reason: :publication_finished
                },
                %PublicationSubscriberLeft{track: ^track, request_id: 1},
                %PublicationSubscriberLeft{track: ^track, request_id: 2}
              ],
              actions: [
                {:cancel_timer, {:publisher_subscription_decision, ^second_handle}},
                {:send_stream, :control, ^pending_error, []},
                {:send_stream, :control, ^active_done, []},
                {:send_stream, :control, ^primary_done, []},
                {:send_stream, :control, ^namespace_done, []}
              ]
            }} =
             Draft16.handle_operation(delivered.state, %FinishPublication{
               publication: publication,
               options: [status: 2, reason: "complete"]
             })

    assert finished.publications == %{}
    assert finished.pending_publisher_subscriptions == %{}
    assert finished.publisher_subscriptions == %{}

    assert {:error, :stale_subscription_request, %Transition{state: ^finished}} =
             Draft16.handle_operation(finished, %AcceptPublicationSubscription{
               request: second_request,
               published_track: track
             })
  end

  defp control_stream do
    %Stream{info: %Info{stream_id: 0, direction: :bidirectional, initiator: :local}}
  end
end
