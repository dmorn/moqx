defmodule MOQX.TransportBench.JSONLTest do
  use ExUnit.Case, async: true

  alias MOQX.TransportBench.JSONL

  test "parses newline-delimited JSON records" do
    body = """
    {"schema_version":"transport-bench-v1","record_type":"step_summary"}
    {"schema_version":"transport-bench-v1","record_type":"step_summary"}
    """

    assert {:ok, [first, second]} = JSONL.parse(body)
    assert first["schema_version"] == "transport-bench-v1"
    assert second["record_type"] == "step_summary"
  end

  test "reports invalid JSON with line numbers" do
    assert {:error, [%{line: 2}]} = JSONL.parse("{\"ok\":true}\nnot-json\n")
  end
end
