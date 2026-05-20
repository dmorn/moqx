defmodule MOQX.TransportBench.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias MOQX.TransportBench.CLI
  alias MOQX.TransportBench.ReleaseCLI

  test "prints top-level runtime usage" do
    assert capture_io(fn -> CLI.main([]) end) =~ "moqx-transport-bench COMMAND"
  end

  test "prints command-specific runtime usage" do
    assert capture_io(fn -> CLI.main(["help", "report"]) end) =~
             "moqx-transport-bench report PATH"
  end

  test "decodes release wrapper arguments" do
    encoded =
      ["report", "/tmp/run.jsonl", "--strict"]
      |> Enum.map_join("\n", &Base.encode64/1)

    assert ReleaseCLI.decode_argv(encoded) == ["report", "/tmp/run.jsonl", "--strict"]
  end
end
