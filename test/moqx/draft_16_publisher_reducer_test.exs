defmodule MOQX.Draft16PublisherReducerTest do
  use ExUnit.Case, async: true

  alias MOQX.Operation.{AddTrack, Publish, PublishObject}
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

  defp control_stream do
    %Stream{info: %Info{stream_id: 0, direction: :bidirectional, initiator: :local}}
  end
end
