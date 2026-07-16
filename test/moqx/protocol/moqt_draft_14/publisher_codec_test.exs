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

  test "decodes the complete absolute-range subscription request without losing parameters" do
    payload =
      <<1, 1, 4, "live", 5, "video", 10, 2, 1, 4, 7, 3, 9, 2, 3, 1, "a", 3, 1, "b">>

    assert {:ok,
            %Messages.Subscribe{
              request_id: 1,
              track_namespace: ["live"],
              track_name: "video",
              subscriber_priority: 10,
              group_order: :descending,
              forward: true,
              filter_type: :absolute_range,
              start_location: {7, 3},
              end_group: 9,
              params: [{3, "a"}, {3, "b"}]
            }} = Codec.decode_subscribe(payload)
  end

  test "round trips every draft-14 subscription filter" do
    filters = [
      {:next_group_start, nil, nil},
      {:largest_object, nil, nil},
      {:absolute_start, {5, 2}, nil},
      {:absolute_range, {5, 2}, 8}
    ]

    for {filter_type, start_location, end_group} <- filters do
      subscribe = %Messages.Subscribe{
        request_id: 1,
        track_namespace: ["live"],
        track_name: "video",
        filter_type: filter_type,
        start_location: start_location,
        end_group: end_group,
        params: [{3, "token"}]
      }

      assert {:ok, [{0x03, payload}], <<>>} =
               subscribe |> Codec.encode() |> Codec.decode_control()

      assert {:ok, ^subscribe} = Codec.decode_subscribe(payload)
    end
  end

  test "rejects malformed subscription delivery semantics at the codec boundary" do
    base = <<1, 1, 4, "live", 5, "video", 10>>

    assert {:error, :invalid_subscribe} = Codec.decode_subscribe(base <> <<3, 1, 2, 0>>)
    assert {:error, :invalid_subscribe} = Codec.decode_subscribe(base <> <<1, 2, 2, 0>>)
    assert {:error, :invalid_subscribe} = Codec.decode_subscribe(base <> <<1, 1, 5, 0>>)
    assert {:error, :invalid_subscribe} = Codec.decode_subscribe(base <> <<1, 1, 4, 9, 0, 8, 0>>)
  end
end
