defmodule MOQXProbe.Benchee.EvidenceTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Benchee.Evidence
  alias MOQXProbe.Benchee.RunReceipt

  defp receipt(expected) do
    RunReceipt.new!(id: :run, target: :quicprobe, expected: expected)
  end

  describe "exact expectations (default)" do
    test "valid when every observed value equals the expectation" do
      evidence =
        Evidence.from_observed(receipt(%{stream_bytes_received: 384}), %{
          stream_bytes_received: 384
        })

      assert evidence.valid
      assert evidence.mismatches == []
    end

    test "invalid when an observed value differs" do
      evidence =
        Evidence.from_observed(receipt(%{stream_bytes_received: 384}), %{
          stream_bytes_received: 128
        })

      refute evidence.valid

      assert evidence.mismatches == [
               %{field: :stream_bytes_received, expected: 384, observed: 128}
             ]
    end
  end

  describe "{:at_least, min} lower-bound expectations" do
    test "valid when observed exactly meets the bound" do
      evidence =
        Evidence.from_observed(
          receipt(%{stream_bytes_received: {:at_least, 384}}),
          %{stream_bytes_received: 384}
        )

      assert evidence.valid
    end

    test "valid when observed exceeds the bound (tail drain delivers more)" do
      evidence =
        Evidence.from_observed(
          receipt(%{stream_bytes_received: {:at_least, 384}}),
          %{stream_bytes_received: 512}
        )

      assert evidence.valid
    end

    test "invalid when observed falls below the bound" do
      evidence =
        Evidence.from_observed(
          receipt(%{stream_bytes_received: {:at_least, 384}}),
          %{stream_bytes_received: 256}
        )

      refute evidence.valid

      assert evidence.mismatches == [
               %{
                 field: :stream_bytes_received,
                 expected: %{comparator: "at_least", value: 384},
                 observed: 256
               }
             ]
    end

    test "invalid when observed is missing or non-numeric" do
      evidence =
        Evidence.from_observed(
          receipt(%{stream_bytes_received: {:at_least, 384}}),
          %{}
        )

      refute evidence.valid
    end

    test "to_map renders the comparator as JSON-serializable data" do
      evidence =
        Evidence.from_observed(
          receipt(%{stream_bytes_received: {:at_least, 384}}),
          %{stream_bytes_received: 512}
        )

      map = Evidence.to_map(evidence)
      assert map.expected == %{stream_bytes_received: %{comparator: "at_least", value: 384}}
      assert JSON.encode!(map)
    end
  end
end
