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

  test "partial setup followed by control reset reports truncation and cleans session state" do
    assert {:ok, %Transition{state: state}} =
             Draft16.handle_transport(
               %State{phase: :setup},
               {:stream_data, control_stream(), <<0x21, 0>>, %{}}
             )

    assert state.control_buffer == <<0x21, 0>>

    assert {:error, {:incomplete_control_stream, :peer_aborted_sending, 2},
            %Transition{state: failed_state}} =
             Draft16.handle_transport(
               state,
               {:stream_event, control_stream(), :peer_aborted_sending, %{error_code: 7}}
             )

    assert failed_state.phase == :closed
    assert failed_state.control_buffer == ""
  end

  test "connection close drops every connection-scoped subscriber handle" do
    subscription = subscription()
    publication = %MOQX.Publication{id: 2, namespace: ["live"]}

    state = %State{
      phase: :ready,
      control_buffer: <<0x21>>,
      stream_decoders: %{4 => %MOQX.Protocol.MOQTDraft16.SubgroupDecoder{}},
      stream_subscriptions: %{4 => 0},
      subscriptions: %{0 => subscription},
      subscription_lifecycles: %{
        0 => %Draft16.SubscriptionState{subscription: subscription, delivery_timeout: 50}
      },
      pending_updates: %{2 => subscription},
      aliases: %{7 => subscription},
      publications: %{
        2 => %{publication: publication, status: :ready, tracks: %{}, options: []}
      }
    }

    assert {:ok,
            %Transition{
              state: %State{
                phase: :closed,
                control_buffer: "",
                stream_decoders: %{},
                stream_subscriptions: %{},
                subscriptions: %{},
                subscription_lifecycles: %{},
                pending_updates: %{},
                aliases: %{},
                publications: %{}
              },
              events: [%MOQX.Event.ConnectionClosed{metadata: %{error_code: 9}}]
            }} =
             Draft16.handle_transport(
               state,
               {:connection_event, :connection, :closed, %{error_code: 9}}
             )

    assert {:ok,
            %Transition{
              state: close_state,
              events: [:connection_ended],
              actions: [{:close_connection, 0}]
            }} = Draft16.handle_operation(state, %MOQX.Operation.Close{})

    assert close_state.phase == :closed
    assert close_state.subscriptions == %{}
    assert close_state.subscription_lifecycles == %{}
    assert close_state.aliases == %{}
    assert close_state.publications == %{}
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
                %MOQX.Event.SubgroupEnded{
                  subscription: ^subscription,
                  group_id: 9,
                  subgroup_id: 3,
                  outcome: :complete
                },
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

  test "partial subgroup reset marks the subgroup incomplete without ending the subscription" do
    subscription = subscription()

    state = %State{
      phase: :ready,
      subscriptions: %{0 => subscription},
      aliases: %{7 => subscription},
      subscription_lifecycles: %{
        0 => %Draft16.SubscriptionState{subscription: subscription, delivery_timeout: 50}
      }
    }

    assert {:ok, %Transition{state: state}} =
             Draft16.handle_transport(
               state,
               {:stream_data, subgroup_stream(4), <<0x34, 7, 9, 3, 0, 5, "hi">>, %{}}
             )

    assert state.stream_subscriptions == %{4 => 0}

    assert {:ok,
            %Transition{
              state: reset_state,
              events: [
                %MOQX.Event.SubgroupEnded{
                  subscription: ^subscription,
                  group_id: 9,
                  subgroup_id: 3,
                  outcome: :reset,
                  error_code: 7,
                  end_of_group?: false
                }
              ]
            }} =
             Draft16.handle_transport(
               state,
               {:stream_event, subgroup_stream(4), :peer_aborted_sending, %{error_code: 7}}
             )

    assert reset_state.stream_decoders == %{}
    assert reset_state.stream_subscriptions == %{}
    assert reset_state.subscriptions[0] == subscription
    assert MapSet.member?(reset_state.subscription_lifecycles[0].processed_streams, 4)
  end

  test "subgroup completion resolves an implicit subgroup id from its first object" do
    subscription = subscription()

    state = %State{
      phase: :ready,
      subscriptions: %{0 => subscription},
      aliases: %{7 => subscription},
      subscription_lifecycles: %{
        0 => %Draft16.SubscriptionState{subscription: subscription, delivery_timeout: 50}
      }
    }

    assert {:ok, %Transition{state: state, events: [%MOQX.Event.ObjectReceived{}]}} =
             Draft16.handle_transport(
               state,
               {:stream_data, subgroup_stream(4), <<0x1A, 7, 9, 5, 4, 1, "x">>, %{}}
             )

    assert {:ok,
            %Transition{
              events: [
                %MOQX.Event.SubgroupEnded{
                  subscription: ^subscription,
                  group_id: 9,
                  subgroup_id: 4,
                  outcome: :complete,
                  end_of_group?: true
                }
              ]
            }} =
             Draft16.handle_transport(
               state,
               {:stream_event, subgroup_stream(4), :peer_finished_sending, %{}}
             )
  end

  test "reset boundary precedes terminal subscription completion" do
    subscription = subscription()

    state = %State{
      phase: :ready,
      subscriptions: %{0 => subscription},
      aliases: %{7 => subscription},
      subscription_lifecycles: %{
        0 => %Draft16.SubscriptionState{subscription: subscription, delivery_timeout: 50}
      }
    }

    state =
      state
      |> Draft16.handle_transport(
        {:stream_data, subgroup_stream(4), <<0x34, 7, 9, 3, 0, 1, "x">>, %{}}
      )
      |> transition_state()
      |> Draft16.handle_transport(
        {:stream_data, control_stream(), <<0x0B, 0, 4, 0, 2, 1, 0>>, %{}}
      )
      |> transition_state()

    assert {:ok,
            %Transition{
              events: [
                %MOQX.Event.SubgroupEnded{
                  subscription: ^subscription,
                  outcome: :reset,
                  error_code: 2
                },
                %MOQX.Event.SubscriptionDone{
                  subscription: ^subscription,
                  completion: %MOQX.Subscription.Completion{
                    processed_streams: 1,
                    timed_out?: false
                  }
                }
              ]
            }} =
             Draft16.handle_transport(
               state,
               {:stream_event, subgroup_stream(4), :peer_aborted_sending, %{error_code: 2}}
             )
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

    for filter <- [
          %MOQX.SubscriptionFilter{type: :next_group_start},
          %MOQX.SubscriptionFilter{type: :largest_object},
          %MOQX.SubscriptionFilter{type: :absolute_start, start_location: {12, 4}},
          %MOQX.SubscriptionFilter{
            type: :absolute_range,
            start_location: {12, 4},
            end_group: 20
          }
        ] do
      assert {:ok, %Transition{actions: [{:send_stream, :control, <<3, _::binary>>, []}]}} =
               Draft16.handle_operation(
                 ready,
                 %Subscribe{track: track, options: [filter: filter]}
               )
    end

    for invalid_filter <- [
          %MOQX.SubscriptionFilter{type: :next_group_start, start_location: {0, 0}},
          %MOQX.SubscriptionFilter{type: :absolute_start},
          %MOQX.SubscriptionFilter{
            type: :absolute_range,
            start_location: {12, 4},
            end_group: 11
          }
        ] do
      assert {:error, {:invalid_subscription_filter, ^invalid_filter}, %Transition{}} =
               Draft16.handle_operation(
                 ready,
                 %Subscribe{track: track, options: [filter: invalid_filter]}
               )
    end
  end

  test "unknown request parameters are lossless and cannot violate KVP typing or uniqueness" do
    track = %MOQX.TrackRef{namespace: ["live"], track: "video"}
    ready = %State{phase: :ready, max_request_id: 0}

    parameters = [
      %MOQX.SubscriptionParameter.Authorization{value: "Bearer token"},
      %MOQX.SubscriptionParameter.Extension{
        protocol: :draft_16,
        identifier: 0x24,
        value: 9
      },
      %MOQX.SubscriptionParameter.Extension{
        protocol: :draft_16,
        identifier: 0x25,
        value: "opaque"
      }
    ]

    assert {:ok, %Transition{actions: [{:send_stream, :control, encoded, []}]}} =
             Draft16.handle_operation(
               ready,
               %Subscribe{track: track, options: [parameters: parameters]}
             )

    assert encoded =~ <<0x03, 12, "Bearer token">>
    assert encoded =~ <<0x03, 9, 1, 6, "opaque">>

    for invalid_parameters <- [
          [
            %MOQX.SubscriptionParameter.Extension{
              protocol: :draft_16,
              identifier: 0x25,
              value: 9
            }
          ],
          [
            %MOQX.SubscriptionParameter.Extension{
              protocol: :draft_16,
              identifier: 0x24,
              value: "wrong wire type"
            }
          ],
          [
            %MOQX.SubscriptionParameter.Extension{
              protocol: :draft_16,
              identifier: 0x20,
              value: 9
            }
          ],
          [
            %MOQX.SubscriptionParameter.Authorization{value: "one"},
            %MOQX.SubscriptionParameter.Authorization{value: "two"}
          ]
        ] do
      assert {:error, :invalid_subscription_parameters, %Transition{}} =
               Draft16.handle_operation(
                 ready,
                 %Subscribe{track: track, options: [parameters: invalid_parameters]}
               )
    end
  end

  test "subscribe and update responses preserve independent deterministic lifecycles" do
    subscription = subscription()

    pending = %State{
      phase: :ready,
      subscriptions: %{0 => subscription},
      subscription_lifecycles: %{
        0 => %Draft16.SubscriptionState{subscription: subscription, delivery_timeout: 50}
      }
    }

    assert {:ok,
            %Transition{
              state: accepted,
              events: [
                %MOQX.Event.SubscriptionAccepted{
                  subscription: ^subscription,
                  parameters: [],
                  track_extensions: []
                }
              ]
            }} =
             Draft16.handle_transport(
               pending,
               {:stream_data, control_stream(), <<4, 0, 3, 0, 7, 0>>, %{}}
             )

    assert accepted.aliases == %{7 => subscription}

    assert {:ok,
            %Transition{
              state: rejected,
              events: [
                %MOQX.Event.SubscriptionFailed{
                  subscription: ^subscription,
                  error: %MOQX.ProtocolError{operation: :subscribe, code: 4, reason: "gone"}
                }
              ]
            }} =
             Draft16.handle_transport(
               pending,
               {:stream_data, control_stream(), <<5, 0, 8, 0, 4, 0, 4, "gone">>, %{}}
             )

    assert rejected.subscriptions == %{}
    assert rejected.subscription_lifecycles == %{}

    updating = %{pending | pending_updates: %{2 => subscription}}

    assert {:ok,
            %Transition{
              state: updated,
              events: [
                %MOQX.Event.SubscriptionUpdated{
                  subscription: ^subscription,
                  parameters: []
                }
              ]
            }} =
             Draft16.handle_transport(
               updating,
               {:stream_data, control_stream(), <<7, 0, 2, 2, 0>>, %{}}
             )

    assert updated.pending_updates == %{}
    assert updated.subscriptions[0] == subscription
  end

  test "subscribe acceptance cannot overwrite another subscription's track alias" do
    first = subscription()

    second = %MOQX.Subscription{
      id: 2,
      track: %MOQX.TrackRef{namespace: ["live"], track: "audio"}
    }

    state = %State{
      phase: :ready,
      subscriptions: %{0 => first, 2 => second},
      aliases: %{7 => first}
    }

    assert {:error, {:duplicate_track_alias, 7}, %Transition{state: ^state}} =
             Draft16.handle_transport(
               state,
               {:stream_data, control_stream(), <<4, 0, 3, 2, 7, 0>>, %{}}
             )
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

    assert {:ok,
            %Transition{
              state: completed,
              events: [%MOQX.Event.SubscriptionDone{subscription: ^subscription}]
            }} =
             Draft16.handle_transport(
               state,
               {:stream_data, control_stream(), <<0x0B, 0, 4, 0, 3, 0, 0>>, %{}}
             )

    assert completed.subscription_lifecycles == %{}
    assert completed.aliases == %{}
  end

  test "publish done times out deterministically when advertised delivery is missing" do
    subscription = subscription()

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
              state: draining,
              events: [],
              actions: [{:start_timer, {:subscription_delivery, 0}, 50}]
            }} =
             Draft16.handle_transport(
               state,
               {:stream_data, control_stream(), <<0x0B, 0, 4, 0, 2, 1, 0>>, %{}}
             )

    assert {:ok,
            %Transition{
              state: completed,
              events: [
                %MOQX.Event.SubscriptionDone{
                  subscription: ^subscription,
                  completion: %MOQX.Subscription.Completion{
                    expected_streams: 1,
                    processed_streams: 0,
                    timed_out?: true
                  }
                }
              ]
            }} =
             Draft16.handle_transport(draining, {:runtime_timeout, {:subscription_delivery, 0}})

    assert completed.subscription_lifecycles == %{}
    assert completed.aliases == %{}
  end

  test "stale or forged subscription handles cannot mutate a live request" do
    subscription = subscription()

    stale = %MOQX.Subscription{
      id: subscription.id,
      track: %MOQX.TrackRef{namespace: ["other"], track: "track"}
    }

    state = %State{
      phase: :ready,
      max_request_id: 2,
      subscriptions: %{subscription.id => subscription}
    }

    assert {:error, :unknown_subscription, %Transition{state: ^state}} =
             Draft16.handle_operation(state, %Unsubscribe{subscription: stale})

    assert {:error, :unknown_subscription, %Transition{state: ^state}} =
             Draft16.handle_operation(
               state,
               %UpdateSubscription{subscription: stale, options: [priority: 1]}
             )
  end

  defp transition_state({:ok, %Transition{state: state}}), do: state

  defp subscription do
    %MOQX.Subscription{
      id: 0,
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }
  end

  defp control_stream do
    %Stream{info: %Info{stream_id: 0, direction: :bidirectional, initiator: :local}}
  end

  defp subgroup_stream(id) do
    %Stream{info: %Info{stream_id: id, direction: :unidirectional, initiator: :peer}}
  end
end
