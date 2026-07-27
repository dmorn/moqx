defmodule MOQX.Draft16SubscriberReducerTest do
  use ExUnit.Case, async: true

  alias MOQX.Operation.{Subscribe, Unsubscribe, UpdateSubscription}
  alias MOQX.Protocol.Draft16
  alias MOQX.Protocol.Draft16.State
  alias MOQX.Protocol.Transition
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info

  test "negotiates setup credit and rejects malformed setup" do
    state = %State{phase: :setup}

    assert {:ok, %Transition{state: %{phase: :ready, max_request_id: 42}, events: [:ready]}} =
             Draft16.handle_transport(
               state,
               {:stream_data, control_stream(), <<0x21, 0, 3, 1, 2, 42>>, %{}}
             )

    assert {:error, :invalid_server_setup, %Transition{}} =
             Draft16.handle_transport(
               state,
               {:stream_data, control_stream(), <<0x21, 0, 2, 0, 99>>, %{}}
             )
  end

  test "control stream termination is a session failure" do
    assert {:error, {:control_stream_terminated, :peer_finished_sending}, %Transition{}} =
             Draft16.handle_transport(
               %State{phase: :ready},
               {:stream_event, control_stream(), :peer_finished_sending, %{}}
             )
  end

  test "delivers datagrams and drains subgroup streams before publish done" do
    subscription = %MOQX.Subscription{
      id: 0,
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    state = %State{
      phase: :ready,
      subscriptions: %{0 => subscription},
      aliases: %{7 => subscription},
      subscription_lifecycles: %{
        0 => %Draft16.SubscriptionState{subscription: subscription, delivery_timeout: 50}
      }
    }

    assert {:ok,
            %Transition{
              events: [
                %MOQX.Event.ObjectReceived{
                  object: %MOQX.Object{
                    subscription: ^subscription,
                    group_id: 9,
                    object_id: 3,
                    publisher_priority: 17,
                    end_of_group?: true,
                    payload: "media"
                  }
                }
              ]
            }} =
             Draft16.handle_transport(
               state,
               {:datagram, :connection, <<2, 7, 9, 3, 17, "media">>, %{}}
             )

    assert {:ok,
            %Transition{
              state: state,
              events: [
                %MOQX.Event.ObjectReceived{
                  object: %MOQX.Object{subscription: ^subscription, payload: "x"}
                }
              ],
              actions: []
            }} =
             Draft16.handle_transport(
               state,
               {:stream_data, subgroup_stream(4), <<0x34, 7, 9, 3, 0, 1, "x">>, %{}}
             )

    assert {:ok,
            %Transition{
              state: state,
              events: [
                %MOQX.Event.SubscriptionDone{
                  subscription: ^subscription,
                  completion: %MOQX.Subscription.Completion{
                    status: :track_ended,
                    expected_streams: 1,
                    processed_streams: 1,
                    timed_out?: false
                  }
                }
              ]
            }} =
             state
             |> Draft16.handle_transport(
               {:stream_data, control_stream(), <<0x0B, 0, 4, 0, 2, 1, 0>>, %{}}
             )
             |> transition_state()
             |> Draft16.handle_transport(
               {:stream_event, subgroup_stream(4), :peer_finished_sending, %{}}
             )

    refute Map.has_key?(state.subscriptions, 0)
    refute Map.has_key?(state.aliases, 7)
    refute Map.has_key?(state.stream_decoders, 4)
  end

  test "encodes every public subscription filter and validates request credit" do
    track = %MOQX.TrackRef{namespace: ["live"], track: "video"}
    ready = %State{phase: :ready, max_request_id: 0}

    assert {:ok, %Transition{actions: [{:send_stream, :control, encoded, []}]}} =
             Draft16.handle_operation(
               ready,
               %Subscribe{
                 track: track,
                 options: [
                   filter: %MOQX.SubscriptionFilter{
                     type: :absolute_range,
                     start_location: {12, 4},
                     end_group: 20
                   },
                   priority: 7,
                   group_order: :descending,
                   delivery_timeout: 900
                 ]
               }
             )

    assert encoded ==
             <<3, 0, 27, 0, 1, 4, "live", 5, "video", 4, 2, 0x43, 0x84, 0x1E, 7, 1, 4, 4, 12, 4,
               20, 1, 2>>

    assert {:error, :request_id_credit_exhausted, %Transition{}} =
             Draft16.handle_operation(%{ready | next_request_id: 2}, %Subscribe{track: track})
  end

  test "request update has an independent lifecycle and rejection keeps subscription active" do
    subscription = %MOQX.Subscription{
      id: 0,
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    state = %State{
      phase: :ready,
      next_request_id: 2,
      max_request_id: 4,
      subscriptions: %{0 => subscription},
      subscription_lifecycles: %{
        0 => %Draft16.SubscriptionState{subscription: subscription, delivery_timeout: 50}
      }
    }

    assert {:ok,
            %Transition{
              state: state,
              events: [{:subscription_updated, ^subscription}],
              actions: [{:send_stream, :control, <<2, _::binary>>, []}]
            }} =
             Draft16.handle_operation(
               state,
               %UpdateSubscription{
                 subscription: subscription,
                 options: [start: :next_group, priority: 4]
               }
             )

    assert state.next_request_id == 4
    assert state.pending_updates[2] == subscription

    assert {:ok,
            %Transition{
              state: state,
              events: [
                %MOQX.Event.SubscriptionUpdateFailed{
                  subscription: ^subscription,
                  error: %MOQX.ProtocolError{operation: :update_subscription, code: 8}
                }
              ]
            }} =
             Draft16.handle_transport(
               state,
               {:stream_data, control_stream(), <<5, 0, 6, 2, 8, 0, 2, "no">>, %{}}
             )

    assert state.subscriptions[0] == subscription
    assert state.pending_updates == %{}
  end

  test "unsubscribe retains delivery state until publish done drains" do
    subscription = %MOQX.Subscription{
      id: 0,
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    lifecycle = %Draft16.SubscriptionState{subscription: subscription, delivery_timeout: 50}

    state = %State{
      phase: :ready,
      subscriptions: %{0 => subscription},
      subscription_lifecycles: %{0 => lifecycle},
      aliases: %{7 => subscription},
      stream_subscriptions: %{4 => 0}
    }

    assert {:ok,
            %Transition{
              state: state,
              events: [{:subscription_ended, ^subscription}],
              actions: [{:send_stream, :control, <<0x0A, 0, 1, 0>>, []}]
            }} = Draft16.handle_operation(state, %Unsubscribe{subscription: subscription})

    assert state.subscriptions == %{}
    assert state.subscription_lifecycles[0] == lifecycle
    assert state.aliases[7] == subscription
    assert state.stream_subscriptions[4] == 0
  end

  defp transition_state({:ok, %Transition{state: state}}), do: state

  defp control_stream do
    %Stream{info: %Info{stream_id: 0, direction: :bidirectional, initiator: :local}}
  end

  defp subgroup_stream(id) do
    %Stream{info: %Info{stream_id: id, direction: :unidirectional, initiator: :peer}}
  end
end
