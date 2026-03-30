defmodule MOQXTest do
  use ExUnit.Case, async: true

  test "public API exposes explicit role-based connect helpers" do
    assert is_function(&MOQX.connect/2)
    assert is_function(&MOQX.connect_publisher/1)
    assert is_function(&MOQX.connect_publisher/2)
    assert is_function(&MOQX.connect_subscriber/1)
    assert is_function(&MOQX.connect_subscriber/2)
    assert is_function(&MOQX.supported_backends/0)
    assert is_function(&MOQX.supported_transports/0)
    assert is_function(&MOQX.close/1)
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

  test "connect/2 validates backend before reaching the NIF" do
    assert_raise ArgumentError,
                 "expected :backend to be :quinn, got: :bogus",
                 fn ->
                   MOQX.connect("https://example.com", role: :publisher, backend: :bogus)
                 end
  end

  test "connect/2 validates transport before reaching the NIF" do
    assert_raise ArgumentError,
                 "expected :transport to be :auto, :raw_quic, :webtransport, or :websocket, got: :bogus",
                 fn ->
                   MOQX.connect("https://example.com", role: :publisher, transport: :bogus)
                 end
  end

  test "connect/2 validates version shape before reaching the NIF" do
    assert_raise ArgumentError,
                 "expected :version to be a string or list of strings, got: :bogus",
                 fn ->
                   MOQX.connect("https://example.com", role: :publisher, version: :bogus)
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

  test "invalid URLs return an error tuple" do
    assert {:error, reason} = MOQX.connect_publisher(":::invalid")
    assert is_binary(reason)
  end
end
