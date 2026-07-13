defmodule MOQX.Protocol.MOQTDraft14.PublisherCodecTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQTDraft14.Codec
  alias MOQX.Protocol.MOQTDraft14.Messages

  test "authorization token uses the standard USE_VALUE token structure" do
    assert Codec.authorization_token("cloudflare-token") == <<3, 0, "cloudflare-token">>

    setup = Codec.client_setup(%{3 => Codec.authorization_token("cloudflare-token")})
    assert {:ok, [{0x20, payload}], <<>>} = Codec.decode_control(setup)

    assert payload ==
             <<1, 0xC0000000FF00000E::64, 2, 2, 0x4064::16, 3, 18, 3, 0, "cloudflare-token">>
  end

  test "encodes and decodes namespace publication lifecycle messages" do
    publish = %Messages.PublishNamespace{
      request_id: 0,
      track_namespace: ["live", "camera-1"],
      params: %{}
    }

    assert {:ok, [{0x06, <<0, 2, 4, "live", 8, "camera-1", 0>>}], <<>>} =
             publish |> Codec.encode() |> Codec.decode_control()

    assert {:ok, %Messages.PublishNamespaceOk{request_id: 0}} =
             Codec.decode_publish_namespace_ok(<<0>>)

    assert {:ok,
            %Messages.PublishNamespaceError{
              request_id: 0,
              error_code: 1,
              reason_phrase: "unauthorized"
            }} = Codec.decode_publish_namespace_error(<<0, 1, 12, "unauthorized">>)

    assert {:ok,
            %Messages.PublishNamespaceCancel{
              track_namespace: ["live", "camera-1"],
              error_code: 1,
              reason_phrase: "expired"
            }} =
             Codec.decode_publish_namespace_cancel(
               <<2, 4, "live", 8, "camera-1", 1, 7, "expired">>
             )
  end

  test "round trips an inbound subscribe and encodes a subgroup object" do
    subscribe = %Messages.Subscribe{
      request_id: 1,
      track_namespace: ["live"],
      track_name: "video.m4s",
      group_order: :ascending,
      filter_type: :largest_object
    }

    assert {:ok, [{0x03, payload}], <<>>} =
             subscribe |> Codec.encode() |> Codec.decode_control()

    assert {:ok, ^subscribe} = Codec.decode_subscribe(payload)

    object = %MOQX.Object{
      group_id: 7,
      subgroup_id: 2,
      object_id: 3,
      publisher_priority: 10,
      payload: "fragment"
    }

    encoded = Codec.encode_subgroup(1, object)
    assert {:ok, decoded, <<>>} = Codec.decode_subgroup_object(encoded)
    assert decoded.track_alias == 1
    assert decoded.group_id == 7
    assert decoded.subgroup_id == 2
    assert decoded.object_id == 3
    assert decoded.payload == "fragment"
  end
end
