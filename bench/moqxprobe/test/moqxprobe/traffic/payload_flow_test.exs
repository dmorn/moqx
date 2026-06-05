defmodule MOQXProbe.Traffic.PayloadFlowTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Traffic.PayloadFlow

  test "builds payloads through a bounded Flow pipeline" do
    payloads =
      1..4
      |> PayloadFlow.from_enumerable(
        mapper: fn sequence -> <<sequence::unsigned-big-32>> end,
        stages: 1,
        min_demand: 1,
        max_demand: 2
      )
      |> Enum.sort()

    assert payloads == [
             <<1::unsigned-big-32>>,
             <<2::unsigned-big-32>>,
             <<3::unsigned-big-32>>,
             <<4::unsigned-big-32>>
           ]
  end
end
