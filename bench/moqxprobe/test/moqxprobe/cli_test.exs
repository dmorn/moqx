defmodule MOQXProbe.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias MOQXProbe.CLI
  alias MOQXProbe.ReleaseCLI

  test "prints top-level runtime usage" do
    output = capture_io(fn -> CLI.main([]) end)

    assert output =~ "moqxprobe COMMAND"
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

  test "documents inline or file path metadata input for iperf3 baseline" do
    assert capture_io(fn -> CLI.main(["help", "iperf3-baseline"]) end) =~
             "--path-json PATH_OR_JSON"
  end

  test "prints measure usage" do
    output = capture_io(fn -> CLI.main(["help", "measure"]) end)

    assert output =~ "reference-client-to-reference-server"
    assert output =~ "moqx-client-to-reference-server"
    assert output =~ "mixed_moqt_shaped"
  end

  test "decodes release wrapper arguments" do
    encoded =
      ["report", "/tmp/run.jsonl", "--strict"]
      |> Enum.map_join("\n", &Base.encode64/1)

    assert ReleaseCLI.decode_argv(encoded) == ["report", "/tmp/run.jsonl", "--strict"]
  end

  test "release wrapper does not inherit a parent release node name" do
    source_wrapper = Path.expand("../../rel/overlays/bin/moqxprobe", __DIR__)

    tmp_dir =
      Path.join(System.tmp_dir!(), "moqxprobe-wrapper-#{System.unique_integer([:positive])}")

    bin_dir = Path.join(tmp_dir, "bin")
    wrapper = Path.join(bin_dir, "moqxprobe")
    runtime = Path.join(bin_dir, "moqxprobe_runtime")

    File.mkdir_p!(bin_dir)
    File.cp!(source_wrapper, wrapper)
    File.chmod!(wrapper, 0o755)

    File.write!(runtime, """
    #!/usr/bin/env sh
    printf 'distribution=%s\\n' "$RELEASE_DISTRIBUTION"
    printf 'node=%s\\n' "$RELEASE_NODE"
    printf 'argv=%s\\n' "$MOQXPROBE_ARGV_B64"
    """)

    File.chmod!(runtime, 0o755)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {output, 0} =
      System.cmd(wrapper, ["report", "/tmp/run.jsonl"],
        env: [{"RELEASE_NODE", "probed@host"}, {"RELEASE_DISTRIBUTION", "name"}]
      )

    assert output =~ "distribution=none"
    assert output =~ "node=moqxprobe_cli_"
    refute output =~ "node=probed@host"
    assert output =~ Base.encode64("report")
    assert output =~ Base.encode64("/tmp/run.jsonl")
  end
end
