defmodule MOQX.CloudflarePublisherReducerTest do
  use ExUnit.Case, async: true

  alias MOQX.Operation.{FinishPublication, Publish}
  alias MOQX.Protocol.CloudflareDraft14
  alias MOQX.Protocol.CloudflareDraft14.State
  alias MOQX.Protocol.MOQTDraft14.Codec
  alias MOQX.Protocol.MOQTDraft14.Messages
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
