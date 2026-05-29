defmodule MOQXProbe.DatagramPayloadTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.DatagramPayload

  test "round trips signed monotonic timestamps" do
    payload = DatagramPayload.encode(12, 64, -57_123)

    assert byte_size(payload) == 64
    assert DatagramPayload.decode(payload) == {:ok, 12, -57_123}
  end

  test "reuses caller-provided padding" do
    padding = DatagramPayload.padding_for_size(64)

    payload = DatagramPayload.encode(12, -57_123, padding)

    assert byte_size(payload) == 64
    assert payload == DatagramPayload.encode(12, 64, -57_123)
    assert DatagramPayload.decode(payload) == {:ok, 12, -57_123}
  end

  test "extracts sequence without interpreting the timestamp" do
    payload = <<42::unsigned-big-64, 123_456_789::unsigned-big-64, 0::size(32)>>

    assert DatagramPayload.sequence(payload) == {:ok, 42}
  end
end
