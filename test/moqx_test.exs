defmodule MOQXTest do
  use ExUnit.Case, async: true

  alias MOQX.Test.Auth

  test "public API exposes explicit role-based connect helpers" do
    assert is_function(&MOQX.connect/2)
    assert is_function(&MOQX.connect_publisher/1)
    assert is_function(&MOQX.connect_publisher/2)
    assert is_function(&MOQX.connect_subscriber/1)
    assert is_function(&MOQX.connect_subscriber/2)
    assert is_function(&MOQX.close/1)
  end

  test "public API exposes subscribe and fetch primitives" do
    assert is_function(&MOQX.subscribe/3)
    assert is_function(&MOQX.subscribe/4)
    assert is_function(&MOQX.subscribe_track/3)
    assert is_function(&MOQX.subscribe_track/4)
    assert is_function(&MOQX.unsubscribe/1)
    assert is_function(&MOQX.fetch/4)
  end

  test "helpers module exposes optional convenience APIs" do
    assert is_function(&MOQX.Helpers.publish_catalog/2)
    assert is_function(&MOQX.Helpers.update_catalog/2)
    assert is_function(&MOQX.Helpers.fetch_catalog/1)
    assert is_function(&MOQX.Helpers.fetch_catalog/2)
    assert is_function(&MOQX.Helpers.await_catalog/1)
    assert is_function(&MOQX.Helpers.await_catalog/2)
    assert is_function(&MOQX.Helpers.await_track_active/1)
    assert is_function(&MOQX.Helpers.await_track_active/2)
    assert is_function(&MOQX.Helpers.write_frame_when_active/2)
    assert is_function(&MOQX.Helpers.write_frame_when_active/3)
  end

  test "unsubscribe/1 rejects non-reference arguments" do
    assert_raise FunctionClauseError, fn -> MOQX.unsubscribe(:not_a_handle) end
    assert_raise FunctionClauseError, fn -> MOQX.unsubscribe("ref") end
    assert_raise FunctionClauseError, fn -> MOQX.unsubscribe(nil) end
  end

  test "connect/2 requires an explicit role" do
    assert_raise ArgumentError, "connect/2 requires :role (:publisher or :subscriber)", fn ->
      MOQX.connect("https://example.com", [])
    end
  end

  test "connect/2 validates the role name before reaching the NIF" do
    assert_raise ArgumentError,
                 "expected :role to be :publisher or :subscriber, got: :both",
                 fn ->
                   MOQX.connect("https://example.com", role: :both)
                 end
  end

  test "connect/2 validates tls shape before reaching the NIF" do
    assert_raise ArgumentError,
                 "expected :tls to be a keyword list, got: :bogus",
                 fn ->
                   MOQX.connect("https://example.com", role: :publisher, tls: :bogus)
                 end
  end

  test "connect/2 validates tls verify mode before reaching the NIF" do
    assert_raise ArgumentError,
                 "expected :tls :verify to be :verify_peer or :insecure, got: :bogus",
                 fn ->
                   MOQX.connect("https://example.com", role: :publisher, tls: [verify: :bogus])
                 end
  end

  test "connect/2 validates tls cacertfile type before reaching the NIF" do
    assert_raise ArgumentError,
                 "expected :tls :cacertfile to be a string path, got: 123",
                 fn ->
                   MOQX.connect("https://example.com", role: :publisher, tls: [cacertfile: 123])
                 end
  end

  test "connect/2 rejects unexpected tls keys before reaching the NIF" do
    assert_raise ArgumentError,
                 "unexpected :tls option :unknown",
                 fn ->
                   MOQX.connect("https://example.com", role: :publisher, tls: [unknown: true])
                 end
  end

  test "subscribe/4 validates rendezvous_timeout_ms before session inspection" do
    assert_raise ArgumentError,
                 "expected :rendezvous_timeout_ms to be a non-negative integer, got: -1",
                 fn ->
                   MOQX.subscribe(:not_a_session, "ns", "track", rendezvous_timeout_ms: -1)
                 end
  end

  test "subscribe/4 still accepts delivery_timeout_ms as a deprecated alias" do
    assert_raise ArgumentError,
                 "expected :delivery_timeout_ms to be a non-negative integer, got: -1",
                 fn ->
                   MOQX.subscribe(:not_a_session, "ns", "track", delivery_timeout_ms: -1)
                 end
  end

  test "subscribe/4 rejects passing both timeout option keys" do
    assert_raise ArgumentError,
                 "subscribe/4 accepts only one of :rendezvous_timeout_ms or :delivery_timeout_ms",
                 fn ->
                   MOQX.subscribe(:not_a_session, "ns", "track",
                     rendezvous_timeout_ms: 1_000,
                     delivery_timeout_ms: 1_000
                   )
                 end
  end

  test "subscribe/4 rejects unexpected opts before session inspection" do
    assert_raise ArgumentError,
                 "unexpected subscribe option :unknown",
                 fn ->
                   MOQX.subscribe(:not_a_session, "ns", "track", unknown: true)
                 end
  end

  test "subscribe/4 validates init_data type before session inspection" do
    assert_raise ArgumentError,
                 "expected :init_data to be a binary, got: 123",
                 fn ->
                   MOQX.subscribe(:not_a_session, "ns", "track", init_data: 123)
                 end
  end

  test "subscribe/4 validates track_meta type before session inspection" do
    assert_raise ArgumentError,
                 "expected :track_meta to be a map, got: :bad",
                 fn ->
                   MOQX.subscribe(:not_a_session, "ns", "track", track_meta: :bad)
                 end
  end

  test "subscribe/4 validates track struct type before session inspection" do
    assert_raise ArgumentError,
                 "expected :track to be a %MOQX.Catalog.Track{}, got: :bad",
                 fn ->
                   MOQX.subscribe(:not_a_session, "ns", "track", track: :bad)
                 end
  end

  test "subscribe_track/4 rejects :track option in opts" do
    track = %MOQX.Catalog.Track{name: "video", depends: [], raw: %{}}

    assert_raise ArgumentError,
                 "subscribe_track/4 does not accept :track in opts",
                 fn ->
                   MOQX.subscribe_track(:not_a_session, "ns", track, track: track)
                 end
  end

  test "fetch/4 validates priority before session inspection" do
    assert_raise ArgumentError,
                 "expected :priority to be an integer in 0..255, got: -1",
                 fn ->
                   MOQX.fetch(:not_a_session, "ns", "track", priority: -1)
                 end
  end

  test "fetch/4 validates group_order before session inspection" do
    assert_raise ArgumentError,
                 "expected :group_order to be :original, :ascending, or :descending, got: :sideways",
                 fn ->
                   MOQX.fetch(:not_a_session, "ns", "track", group_order: :sideways)
                 end
  end

  test "fetch/4 validates start before session inspection" do
    assert_raise ArgumentError,
                 "expected :start to be {group_id, object_id} with non-negative integers, got: :invalid",
                 fn ->
                   MOQX.fetch(:not_a_session, "ns", "track", start: :invalid)
                 end
  end

  test "fetch/4 validates end before session inspection" do
    assert_raise ArgumentError,
                 "expected :end to be {group_id, object_id} with non-negative integers, got: {-1, 0}",
                 fn ->
                   MOQX.fetch(:not_a_session, "ns", "track", end: {-1, 0})
                 end
  end

  test "fetch/4 validates end is not before start" do
    assert_raise ArgumentError,
                 "expected :end to be greater than or equal to :start, got: start={1, 2}, end={1, 1}",
                 fn ->
                   MOQX.fetch(:not_a_session, "ns", "track", start: {1, 2}, end: {1, 1})
                 end
  end

  test "fetch_catalog/2 validates track before session inspection" do
    assert_raise ArgumentError,
                 "expected catalog :track to be a string, got: 123",
                 fn ->
                   MOQX.Helpers.fetch_catalog(:not_a_session, track: 123)
                 end
  end

  test "invalid URLs return a typed request error" do
    assert {:error, %MOQX.RequestError{op: :connect, message: reason}} =
             MOQX.connect_publisher(":::invalid")

    assert is_binary(reason)
  end

  test "auth connect_url normalizes rooted paths and preserves jwt query" do
    url =
      Auth.connect_url(
        "https://relay.example.com/base?ignored=true",
        "/room/demo/",
        "token"
      )

    uri = URI.parse(url)

    assert uri.scheme == "https"
    assert uri.host == "relay.example.com"
    assert uri.path == "/room/demo"
    assert URI.decode_query(uri.query) == %{"jwt" => "token"}
  end

  test "auth connect_url without token normalizes rooted paths and drops query" do
    url = Auth.connect_url("https://relay.example.com/base?ignored=true", "/room/demo/")
    uri = URI.parse(url)

    assert uri.path == "/room/demo"
    assert uri.query == nil
  end
end
