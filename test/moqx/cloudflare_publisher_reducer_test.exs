defmodule MOQX.CloudflarePublisherReducerTest do
  use ExUnit.Case, async: true

  alias MOQX.Operation.{
    AcceptPublicationSubscription,
    AddTrack,
    FinishPublication,
    Publish,
    PublishObject,
    RejectPublicationSubscription
  }

  alias MOQX.Protocol.CloudflareDraft14
  alias MOQX.Protocol.CloudflareDraft14.State
  alias MOQX.Protocol.MOQTDraft14.Codec
  alias MOQX.Protocol.MOQTDraft14.Messages
  alias MOQX.Protocol.Transition
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info

  test "requires secrets to be wrapped before entering protocol state" do
    assert {:error, :authorization_must_be_an_moqx_secret} =
             CloudflareDraft14.init(URI.parse("moqt://relay.example"),
               authorization: "must-not-be-plain"
             )

    secret = MOQX.Secret.new("wrapped")

    assert {:ok, %State{authorization: ^secret}} =
             CloudflareDraft14.init(URI.parse("moqt://relay.example"), authorization: secret)

    state = %State{authorization: MOQX.Secret.new("never-inspect-this")}

    assert {:ok, transition} =
             CloudflareDraft14.handle_transport(state, {:connection_event, :conn, :ready, %{}})

    refute inspect(transition) =~ "never-inspect-this"
    assert inspect(transition) =~ "#MOQX.Sensitive<REDACTED>"
  end

  test "publish namespace errors remove pending publication and emit a typed error" do
    {:ok, transition} =
      CloudflareDraft14.handle_operation(%State{phase: :ready}, %Publish{
        namespace: ["live"]
      })

    publication = transition.events |> List.first() |> elem(1)
    error_frame = <<0x08, 0, 15, 0, 1, 12, "unauthorized">>

    assert {:ok, result} =
             CloudflareDraft14.handle_transport(
               transition.state,
               {:stream_data, control_stream(), error_frame, %{}}
             )

    assert result.state.publications == %{}

    assert [
             %MOQX.Event.PublicationFailed{
               publication: ^publication,
               error: %MOQX.ProtocolError{
                 operation: :publish,
                 code: 1,
                 reason: "unauthorized"
               }
             }
           ] = result.events
  end

  test "namespace cancellation drops publisher state deterministically" do
    {:ok, transition} =
      CloudflareDraft14.handle_operation(%State{phase: :ready}, %Publish{
        namespace: ["live", "camera"]
      })

    publication = transition.events |> List.first() |> elem(1)
    cancel_payload = <<2, 4, "live", 6, "camera", 1, 7, "expired">>
    cancel_frame = frame(0x0C, cancel_payload)

    assert {:ok, result} =
             CloudflareDraft14.handle_transport(
               transition.state,
               {:stream_data, control_stream(), cancel_frame, %{}}
             )

    assert result.state.publications == %{}

    assert [
             %MOQX.Event.PublicationCancelled{
               publication: ^publication,
               error: %MOQX.ProtocolError{code: 1, reason: "expired"}
             }
           ] = result.events
  end

  test "a relay cancellation arriving after local namespace completion is idempotent" do
    {:ok, transition} =
      CloudflareDraft14.handle_operation(%State{phase: :ready}, %Publish{
        namespace: ["live", "camera"]
      })

    {:publication_started, publication} = List.first(transition.events)

    assert {:ok, finished} =
             CloudflareDraft14.handle_operation(transition.state, %FinishPublication{
               publication: publication
             })

    cancel_payload = <<2, 4, "live", 6, "camera", 2, 6, "closed">>

    assert {:ok, result} =
             CloudflareDraft14.handle_transport(
               finished.state,
               {:stream_data, control_stream(), frame(0x0C, cancel_payload), %{}}
             )

    assert result.events == []
    assert result.state.publications == %{}
  end

  test "unknown inbound tracks receive SUBSCRIBE_ERROR" do
    {:ok, transition} =
      CloudflareDraft14.handle_operation(%State{phase: :ready}, %Publish{
        namespace: ["live"]
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "missing"
      })

    assert {:ok, result} =
             CloudflareDraft14.handle_transport(
               transition.state,
               {:stream_data, control_stream(), subscribe, %{}}
             )

    expected =
      Codec.encode(%Messages.SubscribeError{
        request_id: 1,
        error_code: 4,
        reason_phrase: "track not found"
      })

    assert [{:send_stream, :control, ^expected, []}] = result.actions
  end

  test "controlled publications expose inbound subscriptions without replying" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [
          inbound_subscriptions: :controlled,
          subscription_decision_timeout: 250,
          max_pending_subscriptions: 2
        ]
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "future",
        subscriber_priority: 10,
        group_order: :descending,
        forward: false,
        filter_type: :absolute_range,
        start_location: {7, 3},
        end_group: 9,
        params: [{3, "token-a"}, {3, "token-b"}]
      })

    assert {:ok, result} =
             CloudflareDraft14.handle_transport(
               published.state,
               {:stream_data, control_stream(), subscribe, %{}}
             )

    assert [
             %MOQX.Event.PublicationSubscriptionRequested{
               request: %MOQX.PublicationSubscriptionRequest{
                 track: %MOQX.TrackRef{namespace: ["live"], track: "future"},
                 subscriber_priority: 10,
                 group_order: :descending,
                 forward: false,
                 filter: %MOQX.SubscriptionFilter{
                   type: :absolute_range,
                   start_location: {7, 3},
                   end_group: 9
                 },
                 parameters: [
                   %MOQX.SubscriptionParameter.Authorization{value: "token-a"},
                   %MOQX.SubscriptionParameter.Authorization{value: "token-b"}
                 ]
               }
             }
           ] = result.events

    assert [
             {:start_timer, {:publisher_subscription_decision, _handle}, 250}
           ] = result.actions

    [requested] = result.events
    refute inspect(requested) =~ "token-a"

    second =
      Codec.encode(%Messages.Subscribe{
        request_id: 3,
        track_namespace: ["live"],
        track_name: "future"
      })

    assert {:ok, second_pending} =
             CloudflareDraft14.handle_transport(
               result.state,
               {:stream_data, control_stream(), second, %{}}
             )

    assert [%MOQX.Event.PublicationSubscriptionRequested{}] = second_pending.events
    assert map_size(second_pending.state.pending_publisher_subscriptions) == 2

    overflow =
      Codec.encode(%Messages.Subscribe{
        request_id: 5,
        track_namespace: ["live"],
        track_name: "another"
      })

    assert {:ok, overflowed} =
             CloudflareDraft14.handle_transport(
               second_pending.state,
               {:stream_data, control_stream(), overflow, %{}}
             )

    expected_error =
      Codec.encode(%Messages.SubscribeError{
        request_id: 5,
        error_code: 0,
        reason_phrase: "pending subscription limit exceeded"
      })

    assert overflowed.events == []
    assert [{:send_stream, :control, ^expected_error, []}] = overflowed.actions
    assert map_size(overflowed.state.pending_publisher_subscriptions) == 2
  end

  test "a controlled request can register its track before acceptance" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "future",
        group_order: :ascending
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        published.state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events
    handle = request.handle
    {:publication_started, publication} = List.first(published.events)

    assert {:ok, added} =
             CloudflareDraft14.handle_operation(pending.state, %AddTrack{
               publication: publication,
               track: "future"
             })

    {:track_added, track} = List.first(added.events)

    assert {:ok, accepted} =
             CloudflareDraft14.handle_operation(added.state, %AcceptPublicationSubscription{
               request: request,
               published_track: track
             })

    expected_ok =
      Codec.encode(%Messages.SubscribeOk{
        request_id: 1,
        track_alias: 1,
        expires: 0,
        group_order: :ascending,
        largest_location: nil,
        params: %{}
      })

    assert [
             {:cancel_timer, {:publisher_subscription_decision, ^handle}},
             {:send_stream, :control, ^expected_ok, []}
           ] = accepted.actions

    assert [%MOQX.Event.PublicationSubscriberJoined{track: ^track, request_id: 1}] =
             accepted.events
  end

  test "a controlled request can be explicitly rejected only once" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "private"
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        published.state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events
    handle = request.handle

    operation = %RejectPublicationSubscription{
      request: request,
      rejection: %MOQX.SubscriptionRejection{code: :unauthorized, reason: "denied"}
    }

    assert {:error, :wrong_client_subscription_request, _transition} =
             CloudflareDraft14.handle_operation(
               %{pending.state | handle_scope: make_ref()},
               operation
             )

    assert {:ok, rejected} = CloudflareDraft14.handle_operation(pending.state, operation)

    expected_error =
      Codec.encode(%Messages.SubscribeError{
        request_id: 1,
        error_code: 1,
        reason_phrase: "denied"
      })

    assert [
             {:cancel_timer, {:publisher_subscription_decision, ^handle}},
             {:send_stream, :control, ^expected_error, []}
           ] = rejected.actions

    assert {:error, :stale_subscription_request, _transition} =
             CloudflareDraft14.handle_operation(rejected.state, operation)
  end

  test "a controlled request is rejected and invalidated when its decision timer expires" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "late"
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        published.state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events

    assert {:ok, timed_out} =
             CloudflareDraft14.handle_transport(
               pending.state,
               {:runtime_timeout, {:publisher_subscription_decision, request.handle}}
             )

    expected_error =
      Codec.encode(%Messages.SubscribeError{
        request_id: 1,
        error_code: 2,
        reason_phrase: "subscription decision timed out"
      })

    assert [{:send_stream, :control, ^expected_error, []}] = timed_out.actions

    assert [
             %MOQX.Event.PublicationSubscriptionCancelled{
               request: ^request,
               reason: :decision_timeout
             }
           ] = timed_out.events

    assert timed_out.state.pending_publisher_subscriptions == %{}
  end

  test "an inbound unsubscribe cancels a pending controlled request without a reply" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "cancelled"
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        published.state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events
    unsubscribe = Codec.encode(%Messages.Unsubscribe{request_id: 1})

    assert {:ok, cancelled} =
             CloudflareDraft14.handle_transport(
               pending.state,
               {:stream_data, control_stream(), unsubscribe, %{}}
             )

    assert [
             %MOQX.Event.PublicationSubscriptionCancelled{
               request: ^request,
               reason: :unsubscribed
             }
           ] = cancelled.events

    assert [{:cancel_timer, {:publisher_subscription_decision, _handle}}] = cancelled.actions
    assert cancelled.state.pending_publisher_subscriptions == %{}
  end

  test "finishing a publication rejects and invalidates all of its pending requests" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    {:publication_started, publication} = List.first(published.events)

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "pending"
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        published.state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events

    assert {:ok, finished} =
             CloudflareDraft14.handle_operation(pending.state, %FinishPublication{
               publication: publication
             })

    expected_error =
      Codec.encode(%Messages.SubscribeError{
        request_id: 1,
        error_code: 4,
        reason_phrase: "publication finished"
      })

    expected_done =
      Codec.encode(%Messages.PublishNamespaceDone{track_namespace: ["live"]})

    assert [
             {:cancel_timer, {:publisher_subscription_decision, _handle}},
             {:send_stream, :control, ^expected_error, []},
             {:send_stream, :control, ^expected_done, []}
           ] = finished.actions

    assert [
             {:publication_finished, ^publication},
             %MOQX.Event.PublicationSubscriptionCancelled{
               request: ^request,
               reason: :publication_finished
             }
           ] = finished.events

    assert finished.state.pending_publisher_subscriptions == %{}
  end

  test "acceptance replays only objects inside the requested absolute range" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    {:publication_started, publication} = List.first(published.events)

    {:ok, added} =
      CloudflareDraft14.handle_operation(published.state, %AddTrack{
        publication: publication,
        track: "video",
        options: [retention: :all]
      })

    {:track_added, track} = List.first(added.events)

    retained = [
      %MOQX.Object{group_id: 2, object_id: 0, payload: "before"},
      %MOQX.Object{group_id: 2, object_id: 1, payload: "start"},
      %MOQX.Object{group_id: 3, object_id: 0, payload: "end"},
      %MOQX.Object{group_id: 4, object_id: 0, payload: "after"}
    ]

    state =
      Enum.reduce(retained, added.state, fn object, state ->
        {:ok, transition} =
          CloudflareDraft14.handle_operation(state, %PublishObject{
            track: track,
            object: object
          })

        transition.state
      end)

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "video",
        group_order: :ascending,
        filter_type: :absolute_range,
        start_location: {2, 1},
        end_group: 3
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events

    assert {:ok, accepted} =
             CloudflareDraft14.handle_operation(pending.state, %AcceptPublicationSubscription{
               request: request,
               published_track: track
             })

    replayed_payloads =
      for {:open_stream, _key, _options, bytes, [finish: true]} <- accepted.actions do
        bytes
      end

    assert replayed_payloads == [
             Codec.encode_subgroup(1, Enum.at(retained, 1)),
             Codec.encode_subgroup(1, Enum.at(retained, 2))
           ]
  end

  test "rejects datagram delivery without changing draft-14 publication behavior" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{namespace: ["live"]})

    {:publication_started, publication} = List.first(published.events)

    assert {:error, {:unsupported_publication_delivery, :datagram}, %Transition{}} =
             CloudflareDraft14.handle_operation(published.state, %AddTrack{
               publication: publication,
               track: "audio",
               options: [delivery: :datagram]
             })
  end

  test "largest-object filter is fixed when the controlled request arrives" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    {:publication_started, publication} = List.first(published.events)

    {:ok, added} =
      CloudflareDraft14.handle_operation(published.state, %AddTrack{
        publication: publication,
        track: "video",
        options: [retention: :all]
      })

    {:track_added, track} = List.first(added.events)
    before = %MOQX.Object{group_id: 7, object_id: 0, payload: "before"}

    {:ok, before_request} =
      CloudflareDraft14.handle_operation(added.state, %PublishObject{
        track: track,
        object: before
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "video",
        group_order: :ascending,
        filter_type: :largest_object
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        before_request.state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events

    after_request = [
      %MOQX.Object{group_id: 7, object_id: 1, payload: "next"},
      %MOQX.Object{group_id: 8, object_id: 0, payload: "later"}
    ]

    state =
      Enum.reduce(after_request, pending.state, fn object, state ->
        {:ok, transition} =
          CloudflareDraft14.handle_operation(state, %PublishObject{
            track: track,
            object: object
          })

        transition.state
      end)

    assert {:ok, accepted} =
             CloudflareDraft14.handle_operation(state, %AcceptPublicationSubscription{
               request: request,
               published_track: track
             })

    replayed_payloads =
      for {:open_stream, _key, _options, bytes, [finish: true]} <- accepted.actions do
        bytes
      end

    assert replayed_payloads == Enum.map(after_request, &Codec.encode_subgroup(1, &1))

    assert Enum.any?(accepted.actions, fn
             {:send_stream, :control, bytes, []} ->
               bytes ==
                 Codec.encode(%Messages.SubscribeOk{
                   request_id: 1,
                   track_alias: 1,
                   expires: 0,
                   group_order: :ascending,
                   largest_location: {7, 0},
                   params: %{}
                 })

             _other ->
               false
           end)
  end

  test "relay namespace cancellation invalidates controlled requests" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "pending"
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        published.state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events
    cancel_payload = <<1, 4, "live", 1, 7, "expired">>

    assert {:ok, cancelled} =
             CloudflareDraft14.handle_transport(
               pending.state,
               {:stream_data, control_stream(), frame(0x0C, cancel_payload), %{}}
             )

    assert [
             %MOQX.Event.PublicationCancelled{},
             %MOQX.Event.PublicationSubscriptionCancelled{
               request: ^request,
               reason: :publication_cancelled
             }
           ] = cancelled.events

    assert Enum.any?(cancelled.actions, &match?({:cancel_timer, _key}, &1))
    assert cancelled.state.pending_publisher_subscriptions == %{}
  end

  test "connection closure invalidates every pending controlled request" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "pending"
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        published.state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    assert {:ok, closed} =
             CloudflareDraft14.handle_transport(
               pending.state,
               {:connection_event, :conn, :closed, %{error_code: 0}}
             )

    assert closed.state.phase == :closed
    assert closed.state.pending_publisher_subscriptions == %{}
  end

  test "a duplicate inbound request id cannot replace an existing pending request" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "first"
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        published.state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    duplicate =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "replacement"
      })

    assert {:error, :duplicate_subscribe_request, _transition} =
             CloudflareDraft14.handle_transport(
               pending.state,
               {:stream_data, control_stream(), duplicate, %{}}
             )
  end

  test "controlled live tracks retain their largest location without retaining payloads" do
    state = %State{phase: :ready, handle_scope: make_ref()}

    {:ok, published} =
      CloudflareDraft14.handle_operation(state, %Publish{
        namespace: ["live"],
        options: [inbound_subscriptions: :controlled]
      })

    {:publication_started, publication} = List.first(published.events)

    {:ok, added} =
      CloudflareDraft14.handle_operation(published.state, %AddTrack{
        publication: publication,
        track: "video",
        options: [retention: :live]
      })

    {:track_added, track} = List.first(added.events)

    {:ok, object_published} =
      CloudflareDraft14.handle_operation(added.state, %PublishObject{
        track: track,
        object: %MOQX.Object{group_id: 7, object_id: 3, payload: "discarded"}
      })

    subscribe =
      Codec.encode(%Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "video",
        group_order: :ascending,
        filter_type: :largest_object
      })

    {:ok, pending} =
      CloudflareDraft14.handle_transport(
        object_published.state,
        {:stream_data, control_stream(), subscribe, %{}}
      )

    [%MOQX.Event.PublicationSubscriptionRequested{request: request}] = pending.events

    assert {:ok, accepted} =
             CloudflareDraft14.handle_operation(pending.state, %AcceptPublicationSubscription{
               request: request,
               published_track: track
             })

    expected_ok =
      Codec.encode(%Messages.SubscribeOk{
        request_id: 1,
        track_alias: 1,
        expires: 0,
        group_order: :ascending,
        largest_location: {7, 3},
        params: %{}
      })

    assert Enum.any?(accepted.actions, &match?({:send_stream, :control, ^expected_ok, []}, &1))
  end

  defp control_stream do
    %Stream{
      info: %Info{
        stream_id: 0,
        direction: :bidirectional,
        initiator: :local,
        initiator_role: :client,
        local_role: :client,
        send_side?: true,
        receive_side?: true
      }
    }
  end

  defp frame(type, payload), do: <<type, byte_size(payload)::16, payload::binary>>
end
