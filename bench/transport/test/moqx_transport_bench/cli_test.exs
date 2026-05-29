defmodule MOQX.TransportBench.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias MOQX.TransportBench.CLI
  alias MOQX.TransportBench.ReleaseCLI

  test "prints top-level runtime usage" do
    output = capture_io(fn -> CLI.main([]) end)

    assert output =~ "moqx-transport-bench COMMAND"
    assert output =~ "moqx-listener"
    assert output =~ "sender-admission"
  end

  test "prints command-specific runtime usage" do
    assert capture_io(fn -> CLI.main(["help", "report"]) end) =~
             "moqx-transport-bench report PATH"
  end

  test "prints sender admission usage" do
    output = capture_io(fn -> CLI.main(["help", "sender-admission"]) end)

    assert output =~ "moqx-transport-bench sender-admission"
    assert output =~ "--burst-size"
    assert output =~ "--target-rate"
  end

  test "prints MOQX listener usage" do
    output = capture_io(fn -> CLI.main(["help", "moqx-listener"]) end)

    assert output =~ "moqx-transport-bench moqx-listener"
    assert output =~ "reference-client-to-MOQX-listener"
    assert output =~ "mixed_moqt_shaped"
  end

  test "documents inline or file path metadata input for iperf3 baseline" do
    assert capture_io(fn -> CLI.main(["help", "iperf3-baseline"]) end) =~
             "--path-json PATH_OR_JSON"
  end

  test "prints reference comparison usage" do
    output = capture_io(fn -> CLI.main(["help", "reference-comparison"]) end)

    assert output =~ "reference-client-to-reference-server"
    assert output =~ "reference-client-to-moqx-listener"
    assert output =~ "moqx-client-to-reference-server"
    assert output =~ "mixed_moqt_shaped"
  end

  test "decodes release wrapper arguments" do
    encoded =
      ["report", "/tmp/run.jsonl", "--strict"]
      |> Enum.map_join("\n", &Base.encode64/1)

    assert ReleaseCLI.decode_argv(encoded) == ["report", "/tmp/run.jsonl", "--strict"]
  end
end
