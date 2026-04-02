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

  test "public API exposes fetch helpers" do
    assert is_function(&MOQX.fetch/4)
    assert is_function(&MOQX.fetch_catalog/1)
    assert is_function(&MOQX.fetch_catalog/2)
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

  test "invalid URLs return an error tuple" do
    assert {:error, reason} = MOQX.connect_publisher(":::invalid")
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
