defmodule MOQX.Draft16PublisherReducerTest do
  use ExUnit.Case, async: true

  alias MOQX.Operation.{AddTrack, FinishPublication, Publish, PublishObject}
  alias MOQX.Protocol.Draft16
  alias MOQX.Protocol.Draft16.State
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

  defp control_stream do
    %Stream{info: %Info{stream_id: 0, direction: :bidirectional, initiator: :local}}
  end
end
