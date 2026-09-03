defmodule MOQX.Protocol.MOQLite05Test do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQLite05
  alias MOQX.Protocol.{Transition, TransportSpec}
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info

  test "activates immediately and sends one native-QUIC Setup Stream" do
    endpoint = URI.parse("moqt://relay.example/live?token=one")

    assert {:ok, %TransportSpec{} = spec} = MOQLite05.transport_spec(endpoint, [])
    assert spec.alpn == "moq-lite-05"
    assert spec.required_capabilities == MapSet.new([:streams])

    assert {:ok, state} = MOQLite05.init(endpoint, role: :subscriber)

    assert {:ok,
            %Transition{
              state: %{phase: :ready},
              events: [:ready],
              actions: [
                {:open_stream, :setup, [direction: :unidirectional], setup, [finish: true]}
              ]
            }} = MOQLite05.handle_transport(state, {:connection_event, :conn, :ready, %{}})

    assert setup == <<1, 21, 2, 2, 15, "/live?token=one", 3, 1, 2>>
  end

  test "accepts a server Setup without client-only Path or Role" do
    assert {:ok,
            %Transition{
              state: %{
                peer_setup: %MOQX.Protocol.MOQLite05.Messages.Setup{
                  path: nil,
                  role: :both
                },
                group_decoders: %{}
              },
              events: []
            }} =
             MOQLite05.handle_transport(
               %MOQLite05.State{phase: :ready, role: :subscriber},
               {:stream_data, peer_unidirectional_stream(2), <<1, 1, 0>>, %{}}
             )
  end

  test "rejects client-only Path and Role received from the server" do
    state = %MOQLite05.State{phase: :ready, role: :subscriber}

    assert {:error, :peer_setup_contains_client_parameters,
            %Transition{actions: [{:close_connection, 0x3}]}} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, peer_unidirectional_stream(2),
                <<1, 24, 2, 2, 18, "/publish?token=one", 3, 1, 1>>, %{}}
             )
  end

  test "opens Track and Subscribe Streams for an absolute public subscription" do
    track = %MOQX.TrackRef{namespace: ["live", "cam"], track: "video"}

    filter = %MOQX.SubscriptionFilter{
      type: :absolute_range,
      start_location: {4, 0},
      end_group: 9
    }

    operation = %MOQX.Operation.Subscribe{
      track: track,
      options: [
        filter: filter,
        priority: 200,
        group_order: :ascending,
        delivery_timeout: 1_000
      ]
    }

    assert {:ok,
            %Transition{
              state: %{subscriptions: %{0 => %{subscription: subscription}}},
              events: [{:subscription_started, subscription}],
              actions: [
                {:open_stream, {:track, 0}, [direction: :bidirectional, active: true],
                 track_bytes, [finish: true]},
                {:open_stream, {:subscribe, 0}, [direction: :bidirectional, active: true],
                 subscribe_bytes}
              ]
            }} = MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, operation)

    assert subscription == %MOQX.Subscription{id: 0, track: track}
    assert track_bytes == <<6, 15, 8, "live/cam", 5, "video">>

    assert subscribe_bytes ==
             <<2, 22, 0, 8, "live/cam", 5, "video", 200, 1, 0x43, 0xE8, 5, 10>>
  end

  test "rejects public options whose meaning draft-05 cannot preserve" do
    track = %MOQX.TrackRef{namespace: ["live"], track: "video"}

    assert {:error, {:unsupported_subscription_option, :forward, false}, %Transition{}} =
             MOQLite05.handle_operation(
               %MOQLite05.State{phase: :ready},
               %MOQX.Operation.Subscribe{track: track, options: [forward: false]}
             )
  end

  test "accepts a subscription only after TRACK_INFO and SUBSCRIBE_OK are known" do
    operation = %MOQX.Operation.Subscribe{
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    assert {:ok, %Transition{state: state, events: [{:subscription_started, subscription}]}} =
             MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, operation)

    track_info = <<8, 17, 0, 0x43, 0xE8, 0x80, 0x0F, 0x42, 0x40>>

    assert {:ok, %Transition{state: state, events: []}} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, :track_stream, track_info, %{logical_stream: {:track, 0}}}
             )

    assert {:ok,
            %Transition{
              events: [
                %MOQX.Event.SubscriptionAccepted{
                  subscription: ^subscription,
                  track_info: %MOQX.TrackInfo{
                    publisher_priority: 17,
                    publisher_ordered: false,
                    publisher_max_latency: 1_000,
                    timescale: 1_000_000
                  }
                }
              ]
            }} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, :subscribe_stream, <<0, 1, 4>>, %{logical_stream: {:subscribe, 0}}}
             )
  end

  test "updates and gracefully cancels one public subscription on its stream" do
    track = %MOQX.TrackRef{namespace: ["live"], track: "video"}
    subscribe = %MOQX.Operation.Subscribe{track: track}

    assert {:ok, %Transition{state: state, events: [{:subscription_started, subscription}]}} =
             MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, subscribe)

    update = %MOQX.Operation.UpdateSubscription{
      subscription: subscription,
      options: [
        priority: 100,
        group_order: :descending,
        delivery_timeout: 50,
        filter: %MOQX.SubscriptionFilter{type: :absolute_start, start_location: {6, 0}}
      ]
    }

    assert {:ok,
            %Transition{
              state: state,
              events: [{:subscription_updated, ^subscription}],
              actions: [{:send_stream, {:subscribe, 0}, <<5, 100, 0, 50, 7, 0>>, []}]
            }} = MOQLite05.handle_operation(state, update)

    assert {:ok,
            %Transition{
              state: ended,
              events: [{:subscription_ended, ^subscription}],
              actions: [{:send_stream, {:subscribe, 0}, <<>>, [finish: true]}]
            }} =
             MOQLite05.handle_operation(
               state,
               %MOQX.Operation.Unsubscribe{subscription: subscription}
             )

    assert {:ok,
            %Transition{
              state: %{subscriptions: %{1 => _entry}},
              events: [{:subscription_started, %MOQX.Subscription{id: 1}}]
            }} = MOQLite05.handle_operation(ended, subscribe)
  end

  test "delivers Group Stream frames with independent timestamps and derived object IDs" do
    operation = %MOQX.Operation.Subscribe{
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    assert {:ok, %Transition{state: state, events: [{:subscription_started, subscription}]}} =
             MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, operation)

    assert {:ok, %Transition{state: state}} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, :track, <<8, 17, 0, 0x43, 0xE8, 0x80, 0x01, 0x5F, 0x90>>,
                %{logical_stream: {:track, 0}}}
             )

    assert {:ok, %Transition{state: state}} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, :subscribe, <<0, 1, 7>>, %{logical_stream: {:subscribe, 0}}}
             )

    stream = peer_unidirectional_stream(20)

    assert {:ok,
            %Transition{
              state: state,
              events: [
                %MOQX.Event.ObjectReceived{
                  object: %MOQX.Object{
                    subscription: ^subscription,
                    group_id: 7,
                    object_id: 0,
                    timestamp: 90_000,
                    payload: "a"
                  }
                }
              ]
            }} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, stream, <<0, 2, 0, 7, 0x80, 0x02, 0xBF, 0x20, 1, "a">>, %{}}
             )

    assert {:ok,
            %Transition{
              state: state,
              events: [
                %MOQX.Event.ObjectReceived{
                  object: %MOQX.Object{
                    subscription: ^subscription,
                    group_id: 7,
                    object_id: 1,
                    timestamp: 93_000,
                    payload: "b"
                  }
                }
              ]
            }} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, stream, <<0x57, 0x70, 1, "b">>, %{}}
             )

    assert {:ok,
            %Transition{
              state: %{group_decoders: %{}},
              events: [
                %MOQX.Event.SubgroupEnded{
                  subscription: ^subscription,
                  group_id: 7,
                  subgroup_id: nil,
                  outcome: :complete,
                  error_code: nil,
                  end_of_group?: true
                }
              ]
            }} =
             MOQLite05.handle_transport(
               state,
               {:stream_event, stream, :peer_finished_sending, %{}}
             )
  end

  test "buffers Group frames and their boundary until TRACK_INFO accepts the subscription" do
    operation = %MOQX.Operation.Subscribe{
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    {:ok, started} = MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, operation)
    [{:subscription_started, subscription}] = started.events

    {:ok, subscribed} =
      MOQLite05.handle_transport(
        started.state,
        {:stream_data, :subscribe, <<0, 1, 7>>, %{logical_stream: {:subscribe, 0}}}
      )

    stream = peer_unidirectional_stream(22)

    assert {:ok, %Transition{state: grouped, events: []}} =
             MOQLite05.handle_transport(
               subscribed.state,
               {:stream_data, stream, <<0, 2, 0, 7, 0x80, 0x02, 0xBF, 0x20, 1, "a">>, %{}}
             )

    assert {:ok, %Transition{state: finished, events: []}} =
             MOQLite05.handle_transport(
               grouped,
               {:stream_event, stream, :peer_finished_sending, %{}}
             )

    assert {:ok,
            %Transition{
              events: [
                %MOQX.Event.SubscriptionAccepted{subscription: ^subscription},
                %MOQX.Event.ObjectReceived{
                  object: %MOQX.Object{subscription: ^subscription, payload: "a"}
                },
                %MOQX.Event.SubgroupEnded{
                  subscription: ^subscription,
                  group_id: 7,
                  outcome: :complete
                }
              ]
            }} =
             MOQLite05.handle_transport(
               finished,
               {:stream_data, :track, <<8, 17, 0, 0x43, 0xE8, 0x80, 0x01, 0x5F, 0x90>>,
                %{logical_stream: {:track, 0}}}
             )
  end

  test "fails and cleans up a Track Stream that resets or FINs incomplete" do
    operation = %MOQX.Operation.Subscribe{
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    for {event, metadata} <- [
          {:peer_aborted_sending, %{error_code: 7}},
          {:peer_finished_sending, %{}}
        ] do
      {:ok, started} = MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, operation)
      [{:subscription_started, subscription}] = started.events

      {:ok, partial} =
        MOQLite05.handle_transport(
          started.state,
          {:stream_data, :track, <<8, 17>>, %{logical_stream: {:track, 0}}}
        )

      assert {:ok,
              %Transition{
                state: %{subscriptions: %{}},
                events: [%MOQX.Event.SubscriptionFailed{subscription: ^subscription}]
              }} =
               MOQLite05.handle_transport(
                 partial.state,
                 {:stream_event, :track, event, Map.put(metadata, :logical_stream, {:track, 0})}
               )
    end
  end

  test "keeps early Group events behind SUBSCRIBE_OK when TRACK_INFO arrives first" do
    {started, subscription} = started_subscription()
    stream = peer_unidirectional_stream(23)

    {:ok, grouped} =
      MOQLite05.handle_transport(
        started,
        {:stream_data, stream, <<0, 2, 0, 7, 0x80, 0x02, 0xBF, 0x20, 1, "a">>, %{}}
      )

    {:ok, finished} =
      MOQLite05.handle_transport(
        grouped.state,
        {:stream_event, stream, :peer_finished_sending, %{}}
      )

    assert {:ok, %Transition{state: tracked, events: []}} =
             receive_track_info(finished.state)

    assert {:ok,
            %Transition{
              events: [
                %MOQX.Event.SubscriptionAccepted{subscription: ^subscription},
                %MOQX.Event.ObjectReceived{object: %MOQX.Object{payload: "a"}},
                %MOQX.Event.SubgroupEnded{group_id: 7}
              ]
            }} =
             MOQLite05.handle_transport(
               tracked,
               {:stream_data, :subscribe, <<0, 1, 7>>, %{logical_stream: {:subscribe, 0}}}
             )
  end

  test "delays Subscribe completion until TRACK_INFO releases buffered Group events" do
    {started, subscription} = started_subscription()

    {:ok, subscribed} =
      MOQLite05.handle_transport(
        started,
        {:stream_data, :subscribe, <<0, 1, 7, 1, 1, 7>>, %{logical_stream: {:subscribe, 0}}}
      )

    stream = peer_unidirectional_stream(25)

    {:ok, grouped} =
      MOQLite05.handle_transport(
        subscribed.state,
        {:stream_data, stream, <<0, 2, 0, 7, 0x80, 0x02, 0xBF, 0x20, 1, "a">>, %{}}
      )

    {:ok, bounded} =
      MOQLite05.handle_transport(
        grouped.state,
        {:stream_event, stream, :peer_finished_sending, %{}}
      )

    assert {:ok, %Transition{state: waiting, events: []}} =
             MOQLite05.handle_transport(
               bounded.state,
               {:stream_event, :subscribe, :peer_finished_sending,
                %{logical_stream: {:subscribe, 0}}}
             )

    assert {:ok,
            %Transition{
              state: %{subscriptions: %{}},
              events: [
                %MOQX.Event.SubscriptionAccepted{subscription: ^subscription},
                %MOQX.Event.ObjectReceived{object: %MOQX.Object{payload: "a"}},
                %MOQX.Event.SubgroupEnded{group_id: 7},
                %MOQX.Event.SubscriptionDone{subscription: ^subscription}
              ]
            }} = receive_track_info(waiting)
  end

  test "resets an unknown peer unidirectional stream without failing the connection" do
    assert {:ok,
            %Transition{
              actions: [{:abort_stream_receiving, {:peer_stream, 30}, 2}]
            }} =
             MOQLite05.handle_transport(
               %MOQLite05.State{phase: :ready},
               {:stream_data, peer_unidirectional_stream(30), <<0x21, 0>>, %{}}
             )
  end

  test "completes only after every group through SUBSCRIBE_END is accounted" do
    operation = %MOQX.Operation.Subscribe{
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    assert {:ok, %Transition{state: state, events: [{:subscription_started, subscription}]}} =
             MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, operation)

    assert {:ok, %Transition{state: state}} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, :track, <<8, 17, 0, 0x43, 0xE8, 0x80, 0x01, 0x5F, 0x90>>,
                %{logical_stream: {:track, 0}}}
             )

    assert {:ok, %Transition{state: state}} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, :subscribe, <<0, 1, 7>>, %{logical_stream: {:subscribe, 0}}}
             )

    stream = peer_unidirectional_stream(21)

    assert {:ok, %Transition{state: state}} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, stream, <<0, 2, 0, 7>>, %{}}
             )

    assert {:ok, %Transition{state: state}} =
             MOQLite05.handle_transport(
               state,
               {:stream_event, stream, :peer_finished_sending, %{}}
             )

    assert {:ok, %Transition{state: state, events: []}} =
             MOQLite05.handle_transport(
               state,
               {:stream_data, :subscribe, <<1, 1, 8, 2, 3, 8, 8, 42>>,
                %{logical_stream: {:subscribe, 0}}}
             )

    assert {:ok,
            %Transition{
              state: %{subscriptions: %{}},
              events: [
                %MOQX.Event.SubscriptionDone{
                  subscription: ^subscription,
                  completion: %MOQX.Subscription.Completion{
                    status: :track_ended,
                    status_code: 0,
                    reason: "track ended",
                    expected_streams: :unknown,
                    processed_streams: 1,
                    timed_out?: false
                  }
                }
              ]
            }} =
             MOQLite05.handle_transport(
               state,
               {:stream_event, :subscribe, :peer_finished_sending,
                %{logical_stream: {:subscribe, 0}}}
             )
  end

  test "accounts a reset Group Stream without ending its subscription" do
    operation = %MOQX.Operation.Subscribe{
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    {:ok, started} = MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, operation)
    [{:subscription_started, subscription}] = started.events

    {:ok, tracked} =
      MOQLite05.handle_transport(
        started.state,
        {:stream_data, :track, <<8, 17, 0, 0x43, 0xE8, 0x80, 0x01, 0x5F, 0x90>>,
         %{logical_stream: {:track, 0}}}
      )

    stream = peer_unidirectional_stream(24)

    assert {:ok, %Transition{state: state}} =
             MOQLite05.handle_transport(
               tracked.state,
               {:stream_data, stream, <<0, 2, 0, 7>>, %{}}
             )

    assert {:ok,
            %Transition{
              state: %{
                group_decoders: %{},
                subscriptions: %{
                  0 => %{
                    pending_group_events: [
                      %MOQX.Event.SubgroupEnded{
                        subscription: ^subscription,
                        group_id: 7,
                        subgroup_id: nil,
                        outcome: :reset,
                        error_code: 7,
                        end_of_group?: false
                      }
                    ]
                  }
                }
              },
              events: []
            }} =
             MOQLite05.handle_transport(
               state,
               {:stream_event, stream, :peer_aborted_sending, %{error_code: 7}}
             )
  end

  test "completes a track that ends before resolving a start group" do
    operation = %MOQX.Operation.Subscribe{
      track: %MOQX.TrackRef{namespace: ["live"], track: "empty"}
    }

    {:ok, started} = MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, operation)
    [{:subscription_started, subscription}] = started.events

    assert {:ok, %Transition{state: ended, events: []}} =
             MOQLite05.handle_transport(
               started.state,
               {:stream_data, :subscribe, <<1, 1, 9>>, %{logical_stream: {:subscribe, 0}}}
             )

    assert {:ok,
            %Transition{
              state: %{subscriptions: %{}},
              events: [
                %MOQX.Event.SubscriptionDone{
                  subscription: ^subscription,
                  completion: %MOQX.Subscription.Completion{
                    status: :track_ended,
                    processed_streams: 0
                  }
                }
              ]
            }} =
             MOQLite05.handle_transport(
               ended,
               {:stream_event, :subscribe, :peer_finished_sending,
                %{logical_stream: {:subscribe, 0}}}
             )
  end

  test "maps a rejected Subscribe Stream reset to a typed failure and cleanup" do
    operation = %MOQX.Operation.Subscribe{
      track: %MOQX.TrackRef{namespace: ["live"], track: "missing"}
    }

    {:ok, started} = MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, operation)
    [{:subscription_started, subscription}] = started.events

    assert {:ok,
            %Transition{
              state: %{subscriptions: %{}},
              events: [
                %MOQX.Event.SubscriptionFailed{
                  subscription: ^subscription,
                  error: %MOQX.ProtocolError{
                    protocol: :moq_lite_05,
                    operation: :subscribe,
                    code: 42,
                    reason: "subscribe stream reset"
                  }
                }
              ]
            }} =
             MOQLite05.handle_transport(
               started.state,
               {:stream_event, :subscribe, :peer_aborted_sending,
                %{logical_stream: {:subscribe, 0}, error_code: 42}}
             )
  end

  test "closes the native QUIC connection through the shared operation" do
    assert {:ok,
            %Transition{
              events: [:connection_ended],
              actions: [{:close_connection, 0}]
            }} =
             MOQLite05.handle_operation(
               %MOQLite05.State{phase: :ready},
               %MOQX.Operation.Close{reason: :normal}
             )
  end

  defp peer_unidirectional_stream(stream_id) do
    %Stream{
      info: %Info{
        stream_id: stream_id,
        direction: :unidirectional,
        initiator: :peer,
        initiator_role: :server,
        local_role: :client,
        send_side?: false,
        receive_side?: true
      }
    }
  end

  defp started_subscription do
    operation = %MOQX.Operation.Subscribe{
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    {:ok, started} = MOQLite05.handle_operation(%MOQLite05.State{phase: :ready}, operation)
    [{:subscription_started, subscription}] = started.events
    {started.state, subscription}
  end

  defp receive_track_info(state) do
    MOQLite05.handle_transport(
      state,
      {:stream_data, :track, <<8, 17, 0, 0x43, 0xE8, 0x80, 0x01, 0x5F, 0x90>>,
       %{logical_stream: {:track, 0}}}
    )
  end
end
