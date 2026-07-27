defmodule MOQX.CloudflareSubscriptionCompletionTest do
  use ExUnit.Case, async: true

  alias MOQX.Event.{ObjectReceived, SubgroupEnded, SubscriptionDone}
  alias MOQX.Operation.{Subscribe, Unsubscribe}
  alias MOQX.Protocol.CloudflareDraft14
  alias MOQX.Protocol.CloudflareDraft14.State
  alias MOQX.Protocol.CloudflareDraft14.SubscriptionState
  alias MOQX.Protocol.MOQTDraft14.Codec
  alias MOQX.Protocol.MOQTDraft14.Messages
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info

  test "maps the protocol-neutral next-group start policy to draft-14 NEXT_GROUP_START" do
    track = %MOQX.TrackRef{namespace: ["bbb"], track: "video.m4s"}

    assert {:ok, transition} =
             CloudflareDraft14.handle_operation(%State{phase: :ready}, %Subscribe{
               track: track,
               options: [start: :next_group]
             })

    assert [{:send_stream, :control, bytes, []}] = transition.actions
    assert {:ok, [{0x03, payload}], <<>>} = Codec.decode_control(bytes)

    assert {:ok,
            %Messages.Subscribe{
              filter_type: :next_group_start,
              start_location: nil,
              end_group: nil
            }} = Codec.decode_subscribe(payload)
  end

  test "keeps next-object as the compatibility default and rejects unsupported start policies" do
    track = %MOQX.TrackRef{namespace: ["bbb"], track: "video.m4s"}

    for options <- [[], [start: :next_object]] do
      assert {:ok, transition} =
               CloudflareDraft14.handle_operation(%State{phase: :ready}, %Subscribe{
                 track: track,
                 options: options
               })

      assert [{:send_stream, :control, bytes, []}] = transition.actions
      assert {:ok, [{0x03, payload}], <<>>} = Codec.decode_control(bytes)

      assert {:ok, %Messages.Subscribe{filter_type: :largest_object}} =
               Codec.decode_subscribe(payload)
    end

    assert {:error, {:unsupported_subscription_start, :beginning}, transition} =
             CloudflareDraft14.handle_operation(%State{phase: :ready}, %Subscribe{
               track: track,
               options: [start: :beginning]
             })

    assert transition.actions == []
    assert transition.events == []
  end

  test "PUBLISH_DONE waits for a late advertised subgroup stream" do
    track = %MOQX.TrackRef{namespace: ["bbb"], track: "video.m4s"}

    {:ok, subscribed} =
      CloudflareDraft14.handle_operation(%State{phase: :ready}, %Subscribe{
        track: track,
        options: [delivery_timeout: 250]
      })

    subscription = subscribed.events |> List.first() |> elem(1)

    {:ok, accepted} =
      CloudflareDraft14.handle_transport(
        subscribed.state,
        {:stream_data, control_stream(),
         Codec.encode(%Messages.SubscribeOk{
           request_id: 0,
           track_alias: 7,
           expires: 0,
           group_order: :ascending,
           largest_location: nil
         }), %{}}
      )

    {:ok, draining} =
      CloudflareDraft14.handle_transport(
        accepted.state,
        {:stream_data, control_stream(),
         Codec.encode(%Messages.PublishDone{
           request_id: 0,
           status_code: 2,
           stream_count: 1,
           reason_phrase: "track ended"
         }), %{}}
      )

    assert draining.events == []
    assert [{:start_timer, {:subscription_delivery, 0}, 250}] = draining.actions

    bytes =
      Codec.encode_subgroup(7, %MOQX.Object{
        group_id: 3,
        subgroup_id: 0,
        object_id: 0,
        payload: "fragment"
      })

    {:ok, received} =
      CloudflareDraft14.handle_transport(
        draining.state,
        {:stream_data, subgroup_stream(3), bytes, %{}}
      )

    assert [%ObjectReceived{object: %{subscription: ^subscription, payload: "fragment"}}] =
             received.events

    {:ok, completed} =
      CloudflareDraft14.handle_transport(
        received.state,
        {:stream_event, subgroup_stream(3), :peer_finished_sending, %{}}
      )

    assert [
             %SubgroupEnded{
               subscription: ^subscription,
               group_id: 3,
               subgroup_id: 0,
               outcome: :complete,
               end_of_group?: false
             },
             %SubscriptionDone{
               subscription: ^subscription,
               completion: %MOQX.Subscription.Completion{
                 status: :track_ended,
                 expected_streams: 1,
                 processed_streams: 1,
                 timed_out?: false
               }
             }
           ] = completed.events

    assert [{:cancel_timer, {:subscription_delivery, 0}}] = completed.actions
  end

  test "local unsubscribe retains completion state until PUBLISH_DONE and stream drain" do
    track = %MOQX.TrackRef{namespace: ["bbb"], track: "video.m4s"}

    {:ok, subscribed} =
      CloudflareDraft14.handle_operation(%State{phase: :ready}, %Subscribe{
        track: track,
        options: [delivery_timeout: 250]
      })

    subscription = subscribed.events |> List.first() |> elem(1)

    {:ok, accepted} =
      CloudflareDraft14.handle_transport(
        subscribed.state,
        {:stream_data, control_stream(),
         Codec.encode(%Messages.SubscribeOk{
           request_id: subscription.id,
           track_alias: 7,
           expires: 0,
           group_order: :ascending,
           largest_location: nil
         }), %{}}
      )

    bytes =
      Codec.encode_subgroup(7, %MOQX.Object{
        group_id: 3,
        subgroup_id: 0,
        object_id: 0,
        payload: "fragment"
      })

    {:ok, received} =
      CloudflareDraft14.handle_transport(
        accepted.state,
        {:stream_data, subgroup_stream(3), bytes, %{}}
      )

    assert [%ObjectReceived{}] = received.events

    {:ok, unsubscribed} =
      CloudflareDraft14.handle_operation(received.state, %Unsubscribe{
        subscription: subscription
      })

    assert unsubscribed.events == [{:subscription_ended, subscription}]

    assert unsubscribed.actions == [
             {:send_stream, :control, Codec.unsubscribe(subscription.id), []}
           ]

    {:ok, draining} =
      CloudflareDraft14.handle_transport(
        unsubscribed.state,
        {:stream_data, control_stream(),
         Codec.encode(%Messages.PublishDone{
           request_id: subscription.id,
           status_code: 3,
           stream_count: 1,
           reason_phrase: "unsubscribed"
         }), %{}}
      )

    assert draining.events == []

    {:ok, completed} =
      CloudflareDraft14.handle_transport(
        draining.state,
        {:stream_event, subgroup_stream(3), :peer_finished_sending, %{}}
      )

    assert [
             %SubgroupEnded{
               subscription: ^subscription,
               group_id: 3,
               subgroup_id: 0,
               outcome: :complete
             },
             %SubscriptionDone{
               subscription: ^subscription,
               completion: %MOQX.Subscription.Completion{
                 status: :subscription_ended,
                 expected_streams: 1,
                 processed_streams: 1,
                 timed_out?: false
               }
             }
           ] = completed.events

    refute Map.has_key?(completed.state.subscriptions, subscription.id)
    refute Map.has_key?(completed.state.subscription_lifecycles, subscription.id)
    refute Map.has_key?(completed.state.aliases, 7)
  end

  test "delivery timeout completes with the number of processed streams" do
    subscription = %MOQX.Subscription{
      id: 4,
      track: %MOQX.TrackRef{namespace: ["bbb"], track: "video.m4s"}
    }

    state = %State{
      phase: :ready,
      subscriptions: %{4 => subscription},
      subscription_lifecycles: %{
        4 => %SubscriptionState{
          subscription: subscription,
          delivery_timeout: 10,
          completion: %Messages.PublishDone{
            request_id: 4,
            status_code: 6,
            stream_count: 2,
            reason_phrase: "too far behind"
          },
          delivery_timer_started?: true,
          processed_streams: MapSet.new()
        }
      }
    }

    assert {:ok, transition} =
             CloudflareDraft14.handle_transport(
               state,
               {:runtime_timeout, {:subscription_delivery, 4}}
             )

    assert [%SubscriptionDone{completion: completion}] = transition.events
    assert completion.status == :too_far_behind
    assert completion.processed_streams == 0
    assert completion.timed_out?
  end

  test "Cloudflare reset marks one subgroup incomplete and a later close is idempotent" do
    subscription = %MOQX.Subscription{
      id: 4,
      track: %MOQX.TrackRef{namespace: ["bbb"], track: "video.m4s"}
    }

    state = %State{
      phase: :ready,
      subscriptions: %{4 => subscription},
      aliases: %{7 => subscription},
      subscription_lifecycles: %{
        4 => %SubscriptionState{subscription: subscription, delivery_timeout: 250}
      }
    }

    bytes =
      Codec.encode_subgroup(7, %MOQX.Object{
        group_id: 3,
        subgroup_id: 0,
        object_id: 0,
        payload: "fragment"
      })

    assert {:ok, received} =
             CloudflareDraft14.handle_transport(
               state,
               {:stream_data, subgroup_stream(9), bytes, %{}}
             )

    assert {:ok,
            %MOQX.Protocol.Transition{
              state: reset_state,
              events: [
                %SubgroupEnded{
                  subscription: ^subscription,
                  group_id: 3,
                  subgroup_id: 0,
                  outcome: :reset,
                  error_code: 2
                }
              ]
            }} =
             CloudflareDraft14.handle_transport(
               received.state,
               {:stream_event, subgroup_stream(9), :peer_aborted_sending, %{error_code: 2}}
             )

    assert reset_state.subscriptions[4] == subscription
    assert MapSet.member?(reset_state.subscription_lifecycles[4].processed_streams, 9)

    assert {:ok, %MOQX.Protocol.Transition{state: ^reset_state, events: []}} =
             CloudflareDraft14.handle_transport(
               reset_state,
               {:stream_event, subgroup_stream(9), :closed, %{}}
             )
  end

  test "Cloudflare FIN in a partial object is a protocol failure and releases stream state" do
    subscription = %MOQX.Subscription{
      id: 4,
      track: %MOQX.TrackRef{namespace: ["bbb"], track: "video.m4s"}
    }

    state = %State{
      phase: :ready,
      subscriptions: %{4 => subscription},
      aliases: %{7 => subscription},
      subscription_lifecycles: %{
        4 => %SubscriptionState{subscription: subscription, delivery_timeout: 250}
      }
    }

    partial = <<0x15, 7, 3, 0, 0, 0, 0, 3, "a">>

    assert {:ok, received} =
             CloudflareDraft14.handle_transport(
               state,
               {:stream_data, subgroup_stream(9), partial, %{}}
             )

    assert {:error, {:incomplete_subgroup_stream, %{header_decoded?: true, buffered_bytes: 4}},
            %MOQX.Protocol.Transition{state: failed_state}} =
             CloudflareDraft14.handle_transport(
               received.state,
               {:stream_event, subgroup_stream(9), :peer_finished_sending, %{}}
             )

    assert failed_state.stream_decoders == %{}
    assert failed_state.stream_subscriptions == %{}
  end

  test "delivery timeout must be a non-negative integer" do
    track = %MOQX.TrackRef{namespace: ["bbb"], track: "video.m4s"}

    assert {:error, :invalid_delivery_timeout, _transition} =
             CloudflareDraft14.handle_operation(%State{phase: :ready}, %Subscribe{
               track: track,
               options: [delivery_timeout: -1]
             })
  end

  defp control_stream, do: stream(0, :bidirectional, :local)
  defp subgroup_stream(id), do: stream(id, :unidirectional, :peer)

  defp stream(id, direction, initiator) do
    %Stream{
      info: %Info{
        stream_id: id,
        direction: direction,
        initiator: initiator,
        initiator_role: if(initiator == :local, do: :client, else: :server),
        local_role: :client,
        send_side?: initiator == :local,
        receive_side?: true
      }
    }
  end
end
