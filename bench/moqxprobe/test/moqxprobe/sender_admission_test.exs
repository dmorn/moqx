defmodule MOQXProbe.SenderAdmissionTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.SenderAdmission

  test "measures accepted sends by burst" do
    result =
      SenderAdmission.measure_admissions(
        fn _payload -> :ok end,
        <<0, 1, 2>>,
        10,
        4
      )

    assert result.accepted == 10
    assert result.errors == 0
    assert result.error_reasons == %{}
    assert Enum.reverse(result.burst_counts) == [4, 4, 2]
    assert length(result.burst_durations_us) == 3
    assert result.duration_us >= 0
  end

  test "counts send errors without stopping the measurement" do
    result =
      SenderAdmission.measure_admissions(
        fn _payload -> {:error, :blocked} end,
        <<0>>,
        3,
        2
      )

    assert result.accepted == 0
    assert result.errors == 3
    assert result.error_reasons == %{":blocked" => 3}
    assert Enum.reverse(result.burst_counts) == [2, 1]
  end
end
