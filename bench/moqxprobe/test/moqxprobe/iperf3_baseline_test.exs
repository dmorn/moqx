defmodule MOQXProbe.Iperf3BaselineTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Iperf3Baseline
  alias ProbeLedger.Contract
  alias ProbeLedger.JSONL

  test "emits a valid timeout record and terminates the iperf3 command" do
    dir = tmp_dir()
    output_path = Path.join(dir, "timeout.jsonl")
    pid_path = Path.join(dir, "fake-iperf3.pid")
    fake_iperf3 = fake_iperf3_sleep_command(dir, pid_path)

    started_at = System.monotonic_time(:millisecond)

    Iperf3Baseline.main(
      [
        "--server",
        "127.0.0.1",
        "--port",
        "55211",
        "--tcp-duration",
        "1",
        "--timeout-margin-seconds",
        "1",
        "--no-udp",
        "--iperf3-command",
        fake_iperf3,
        "--output",
        output_path,
        "--run-id",
        "timeout-test"
      ],
      script: "test iperf3-baseline"
    )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms < 5_000

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["methodology"]["timeout_seconds"] == 2.0

    assert record["methodology"]["stop_conditions"] == [
             "iperf3_nonzero_exit",
             "iperf3_step_timeout"
           ]

    assert record["limits"]["first_break_symptom"] == "step_timeout"
    assert record["limits"]["stopped_by"] == "iperf3_step_timeout"
    refute record["limits"]["protocol_error"]
    assert record["errors"]["close_reason"] == "timeout"
    assert record["errors"]["error_code"] == 124
    assert record["errors"]["message"] == "iperf3 timed out after 2s"
    assert record["metrics"]["iperf3_exit_status"] == 124

    pid = pid_path |> File.read!() |> String.trim() |> String.to_integer()
    refute os_process_alive?(pid)
  end

  defp fake_iperf3_sleep_command(dir, pid_path) do
    script_path = Path.join(dir, "fake-iperf3")

    File.write!(script_path, """
    #!/usr/bin/env sh
    printf '%s' "$$" > '#{pid_path}'
    exec sleep 10
    """)

    File.chmod!(script_path, 0o755)
    script_path
  end

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "moqx-iperf3-baseline-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
