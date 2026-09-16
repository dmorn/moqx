defmodule MOQX.Draft18ReducerTest do
  use ExUnit.Case, async: true

  alias MOQX.Operation.{PublishObject, Subscribe}
  alias MOQX.Protocol.Draft18
  alias MOQX.Protocol.Draft18.State
  alias MOQX.Protocol.MOQTDraft18.{Codec, SubgroupDecoder}
  alias MOQX.Protocol.Transition
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info

  test "transport spec enables and requires QUIC datagrams" do
    endpoint = URI.parse("moqt://relay.example")

    assert {:ok, spec} = Draft18.transport_spec(endpoint, [])
    assert spec.connect_options[:datagram_receive_enabled] == 1
    assert spec.required_capabilities == MapSet.new([:streams, :datagrams])
  end

  test "setup uses the peer unidirectional control stream and has no request credit" do
    state = %State{phase: :setup}

    assert {:ok,
            %Transition{
              state: %State{phase: :ready, peer_control_stream: 3},
              events: [:ready]
            }} =
             Draft18.handle_transport(
               state,
               {:stream_data, peer_unidirectional_stream(3), <<0xAF, 0, 0, 0>>, %{}}
             )
  end

  test "data before peer setup and local control stream termination fail the session" do
    assert {:error, {:server_setup_required, 0x14}, %Transition{}} =
             Draft18.handle_transport(
               %State{phase: :setup},
               {:stream_data, peer_unidirectional_stream(3), <<0x14>>, %{}}
             )

    assert {:error, {:control_stream_terminated, :peer_aborted_sending},
            %Transition{state: %State{phase: :closed}}} =
             Draft18.handle_transport(
               %State{phase: :ready},
               {:stream_event, local_unidirectional_stream(2), :peer_aborted_sending,
                %{logical_stream: :control}}
             )
  end

  test "concurrent subscribe responses correlate by request stream" do
    track_a = %MOQX.TrackRef{namespace: ["live"], track: "a"}
    track_b = %MOQX.TrackRef{namespace: ["live"], track: "b"}

    assert {:ok, %Transition{state: pending_a, actions: [open_a]}} =
             Draft18.handle_operation(%State{phase: :ready}, %Subscribe{track: track_a})

    assert {:open_stream, {:subscribe, 0}, [direction: :bidirectional, active: true], _} = open_a

    assert {:ok, %Transition{state: pending_b, actions: [open_b]}} =
             Draft18.handle_operation(pending_a, %Subscribe{track: track_b})

    assert {:open_stream, {:subscribe, 2}, [direction: :bidirectional, active: true], _} = open_b

    subscription_a = pending_b.subscriptions[0]
    subscription_b = pending_b.subscriptions[2]

    assert {:ok,
            %Transition{
              state: accepted_b,
              events: [%MOQX.Event.SubscriptionAccepted{subscription: ^subscription_b}]
            }} =
             Draft18.handle_transport(
               pending_b,
               {:stream_data, local_bidirectional_stream(8), Codec.subscribe_ok(22),
                %{logical_stream: {:subscribe, 2}}}
             )

    assert accepted_b.aliases == %{22 => subscription_b}

    assert {:ok,
            %Transition{
              state: accepted_a,
              events: [%MOQX.Event.SubscriptionAccepted{subscription: ^subscription_a}]
            }} =
             Draft18.handle_transport(
               accepted_b,
               {:stream_data, local_bidirectional_stream(4), Codec.subscribe_ok(11),
                %{logical_stream: {:subscribe, 0}}}
             )

    assert accepted_a.aliases == %{11 => subscription_a, 22 => subscription_b}
  end

  test "peer subscribe rejection is sent on that request stream" do
    request = Codec.subscribe(1, %MOQX.TrackRef{namespace: ["missing"], track: "video"}, [])

    assert {:ok,
            %Transition{
              actions: [
                {:send_stream, {:peer_stream, 5}, response, [finish: true]}
              ]
            }} =
             Draft18.handle_transport(
               %State{phase: :ready},
               {:stream_data, peer_bidirectional_stream(5), request, %{}}
             )

    assert {:ok, [{0x05, payload}], <<>>} = Codec.decode_control(response)

    assert {:ok, %{error_code: 0x10, reason: "track not found"}} =
             Codec.decode_request_error(payload)
  end

  test "peer request update changes only supplied subscription fields" do
    stream_key = {:peer_stream, 5}
    subgroup_key = {:publication, 1, 7, 0}

    subscription = %{
      stream_key: stream_key,
      forward: true,
      subscriber_priority: 128,
      filter: %MOQX.SubscriptionFilter{type: :largest_object},
      subgroup_streams: %{{7, 0} => %{key: subgroup_key, object_id: 2}}
    }

    update =
      Codec.request_update(3,
        forward: false,
        priority: 7,
        filter: %MOQX.SubscriptionFilter{type: :next_group_start}
      )

    assert {:ok,
            %Transition{
              state: updated,
              actions: [
                {:abort_stream_sending, ^subgroup_key, 0x01},
                {:send_stream, ^stream_key, response, []}
              ]
            }} =
             Draft18.handle_transport(
               %State{phase: :ready, publisher_subscriptions: %{1 => subscription}},
               {:stream_data, peer_bidirectional_stream(5), update, %{}}
             )

    assert updated.publisher_subscriptions[1].forward == false
    assert updated.publisher_subscriptions[1].subscriber_priority == 7
    assert updated.publisher_subscriptions[1].filter.type == :next_group_start
    assert updated.publisher_subscriptions[1].subgroup_streams == %{}
    assert MapSet.member?(updated.peer_request_ids, 3)
    assert response == Codec.request_ok()
  end

  test "reserved subgroup stream type is rejected before decoding a subgroup" do
    assert {:error, :unknown_unidirectional_stream_type, %Transition{}} =
             Draft18.handle_transport(
               %State{phase: :ready},
               {:stream_data, peer_unidirectional_stream(7), <<0x16>>, %{}}
             )
  end

  test "padding streams discard zero bytes and reject nonzero bytes" do
    type = Codec.encode_varint(0x132B3E28)
    stream = peer_unidirectional_stream(7)

    assert {:ok, %Transition{state: padding}} =
             Draft18.handle_transport(
               %State{phase: :ready},
               {:stream_data, stream, type <> <<0, 0>>, %{}}
             )

    assert {:ok, %Transition{state: ^padding}} =
             Draft18.handle_transport(padding, {:stream_data, stream, <<0>>, %{}})

    assert {:error, :invalid_padding_stream, %Transition{}} =
             Draft18.handle_transport(padding, {:stream_data, stream, <<1>>, %{}})
  end

  test "incomplete subgroup data is bounded across streams" do
    object = %MOQX.Object{
      group_id: 1,
      subgroup_id: 0,
      object_id: 0,
      timestamp: 0,
      payload: :binary.copy("x", 20)
    }

    encoded = Codec.encode_subgroup(3, object)
    incomplete = binary_part(encoded, 0, byte_size(encoded) - 1)

    assert {:error, :data_buffer_limit_exceeded, %Transition{}} =
             Draft18.handle_transport(
               %State{phase: :ready, max_buffered_data_bytes: 4},
               {:stream_data, peer_unidirectional_stream(7), incomplete, %{}}
             )
  end

  test "publisher keeps one stream per subgroup and finishes it at group completion" do
    scope = make_ref()
    publication = %MOQX.Publication{id: 0, namespace: ["live"], scope: scope}

    track = %MOQX.PublishedTrack{
      scope: scope,
      id: 0,
      publication: publication,
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"},
      retention: :live
    }

    track_entry = %{
      track: track,
      origin: :publish,
      request_id: 2,
      track_alias: 4,
      delivery: :subgroup,
      status: :ready,
      stream_count: 0,
      subgroup_streams: %{},
      options: []
    }

    state = %State{
      phase: :ready,
      handle_scope: scope,
      publications: %{
        0 => %{publication: publication, status: :ready, tracks: %{"video" => track_entry}}
      }
    }

    extension = %MOQX.Extension{protocol: :draft_18, identifier: 0x3D, value: "trace"}

    first = %MOQX.Object{
      group_id: 1,
      subgroup_id: 0,
      object_id: 0,
      extensions: [extension],
      payload: "a"
    }

    assert {:ok, %Transition{state: open, actions: [open_action]}} =
             Draft18.handle_operation(state, %PublishObject{track: track, object: first})

    assert {:open_stream, key, [direction: :unidirectional], first_bytes, [finish: false]} =
             open_action

    changed_priority = %{first | object_id: 1, publisher_priority: 7}

    assert {:error, :subgroup_priority_changed, %Transition{state: ^open}} =
             Draft18.handle_operation(open, %PublishObject{
               track: track,
               object: changed_priority
             })

    last = %{first | object_id: 1, extensions: [], payload: "b", end_of_group?: true}

    assert {:ok, %Transition{state: finished, actions: [send_action]}} =
             Draft18.handle_operation(open, %PublishObject{track: track, object: last})

    assert {:send_stream, ^key, last_bytes, [finish: true]} = send_action
    assert finished.publications[0].tracks["video"].stream_count == 1
    assert finished.publications[0].tracks["video"].subgroup_streams == %{}

    assert {:ok, decoder, [decoded_first, decoded_last, end_of_group]} =
             SubgroupDecoder.push(%SubgroupDecoder{}, first_bytes <> last_bytes)

    assert decoded_first.extensions == [extension]
    assert decoded_last.payload == "b"
    assert end_of_group.status == :end_of_group
    assert decoder.end_of_group?
  end

  test "publish done unknown stream count drains until timeout and reports unknown" do
    subscription = %MOQX.Subscription{
      id: 0,
      track: %MOQX.TrackRef{namespace: ["live"], track: "video"}
    }

    state = %State{
      phase: :ready,
      subscriptions: %{0 => subscription},
      subscription_lifecycles: %{
        0 => %Draft18.SubscriptionState{subscription: subscription, delivery_timeout: 25}
      }
    }

    done = Codec.publish_done(2, 0x3FFF_FFFF_FFFF_FFFF, "ended")

    assert {:ok,
            %Transition{
              state: draining,
              actions: [{:start_timer, {:subscription_delivery, 0}, 25}]
            }} =
             Draft18.handle_transport(
               state,
               {:stream_data, local_bidirectional_stream(4), done,
                %{logical_stream: {:subscribe, 0}}}
             )

    assert {:ok, %Transition{state: ^draining}} =
             Draft18.handle_transport(
               draining,
               {:stream_event, local_bidirectional_stream(4), :peer_finished_sending,
                %{logical_stream: {:subscribe, 0}}}
             )

    assert {:ok,
            %Transition{
              events: [
                %MOQX.Event.SubscriptionDone{
                  subscription: ^subscription,
                  completion: %MOQX.Subscription.Completion{
                    status: :track_ended,
                    expected_streams: :unknown,
                    timed_out?: true
                  }
                }
              ]
            }} =
             Draft18.handle_transport(draining, {:runtime_timeout, {:subscription_delivery, 0}})
  end

  test "abrupt local subscribe stream termination fails only that request" do
    track = %MOQX.TrackRef{namespace: ["live"], track: "video"}
    {:ok, pending} = Draft18.handle_operation(%State{phase: :ready}, %Subscribe{track: track})
    subscription = pending.state.subscriptions[0]

    assert {:ok,
            %Transition{
              state: ended,
              events: [%MOQX.Event.SubscriptionFailed{subscription: ^subscription}]
            }} =
             Draft18.handle_transport(
               pending.state,
               {:stream_event, local_bidirectional_stream(4), :peer_aborted_sending,
                %{logical_stream: {:subscribe, 0}, error_code: 1}}
             )

    assert ended.phase == :ready
    assert ended.subscriptions == %{}
  end

  defp local_bidirectional_stream(id) do
    %Stream{info: %Info{stream_id: id, direction: :bidirectional, initiator: :local}}
  end

  defp peer_bidirectional_stream(id) do
    %Stream{info: %Info{stream_id: id, direction: :bidirectional, initiator: :peer}}
  end

  defp peer_unidirectional_stream(id) do
    %Stream{info: %Info{stream_id: id, direction: :unidirectional, initiator: :peer}}
  end

  defp local_unidirectional_stream(id) do
    %Stream{info: %Info{stream_id: id, direction: :unidirectional, initiator: :local}}
  end
end
