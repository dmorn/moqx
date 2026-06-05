defmodule MOQXProbe.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias MOQXProbe.CLI
  alias MOQXProbe.ReleaseCLI

  test "prints top-level runtime usage" do
    output = capture_io(fn -> CLI.main([]) end)

    assert output =~ "moqxprobe COMMAND"
    assert output =~ "moqx-listener"
    assert output =~ "sender-admission"
  end

  test "prints command-specific runtime usage" do
    assert capture_io(fn -> CLI.main(["help", "report"]) end) =~
             "moqxprobe report PATH"
  end

  test "prints sender admission usage" do
    output = capture_io(fn -> CLI.main(["help", "sender-admission"]) end)

    assert output =~ "moqxprobe sender-admission"
    assert output =~ "--burst-size"
    assert output =~ "--target-rate"
  end

  test "prints MOQX listener usage" do
    output = capture_io(fn -> CLI.main(["help", "moqx-listener"]) end)

    assert output =~ "moqxprobe moqx-listener"
    assert output =~ "reference-client-to-MOQX-listener"
    assert output =~ "mixed_moqt_shaped"
  end

  test "documents inline or file path metadata input for iperf3 baseline" do
    assert capture_io(fn -> CLI.main(["help", "iperf3-baseline"]) end) =~
             "--path-json PATH_OR_JSON"
  end

  test "prints measure usage" do
    output = capture_io(fn -> CLI.main(["help", "measure"]) end)

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

  test "dispatches Burrito wrapper arguments" do
    output = capture_io(fn -> ReleaseCLI.main_from_burrito(fn -> ["help"] end) end)

    assert output =~ "moqxprobe COMMAND"
  end
end
