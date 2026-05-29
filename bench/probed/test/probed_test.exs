defmodule ProbedTest do
  use ExUnit.Case, async: true

  test "reports its application version" do
    assert Probed.version() == ~c"0.1.0"
  end
end
