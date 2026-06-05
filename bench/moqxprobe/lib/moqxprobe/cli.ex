defmodule MOQXProbe.CLI do
  @moduledoc false

  alias MOQXProbe.Iperf3Baseline
  alias MOQXProbe.Measure
  alias MOQXProbe.MoqxListener
  alias MOQXProbe.QuicerSelfPair
  alias MOQXProbe.ReportCommand
  alias MOQXProbe.SenderAdmission

  @runtime_program "moqxprobe"

  def main(argv, opts \\ []) do
    case argv do
      [] ->
        IO.puts(usage(program(opts)))

      ["help"] ->
        IO.puts(usage(program(opts)))

      ["-h"] ->
        IO.puts(usage(program(opts)))

      ["--help"] ->
        IO.puts(usage(program(opts)))

      ["help", command | _rest] ->
        dispatch(command, ["--help"], opts)

      [command | command_argv] ->
        dispatch(command, command_argv, opts)
    end
  end

  def usage(program \\ @runtime_program) do
    """
    Usage:
      #{program} COMMAND [options]

    Commands:
      iperf3-baseline   Run the iperf3 raw path baseline
      self-pair         Run the quicer self-pair calibration benchmark
      sender-admission  Run the local DATAGRAM sender admission microbenchmark
      measure           Run selected QUIC measurement benchmarks
      moqx-listener     Run a MOQX.Transport echo/drain listener
      report            Render and validate transport benchmark JSONL

    Use "#{program} help COMMAND" for command-specific options.
    """
  end

  defp dispatch(command, argv, opts) when command in ["iperf3-baseline", "iperf3_baseline"] do
    Iperf3Baseline.main(argv, script: command_script(:iperf3_baseline, opts))
  end

  defp dispatch(command, argv, opts) when command in ["self-pair", "self_pair"] do
    QuicerSelfPair.main(argv, script: command_script(:self_pair, opts))
  end

  defp dispatch(command, argv, opts) when command in ["sender-admission", "sender_admission"] do
    SenderAdmission.main(argv, script: command_script(:sender_admission, opts))
  end

  defp dispatch("measure", argv, opts) do
    Measure.main(argv, script: command_script(:measure, opts))
  end

  defp dispatch(command, argv, opts) when command in ["moqx-listener", "moqx_listener"] do
    MoqxListener.main(argv, script: command_script(:moqx_listener, opts))
  end

  defp dispatch("report", argv, opts) do
    ReportCommand.main(argv, script: command_script(:report, opts))
  end

  defp dispatch(command, _argv, opts) do
    IO.puts(:stderr, "Unknown command #{inspect(command)}.\n\n#{usage(program(opts))}")
    System.halt(2)
  end

  defp command_script(command, opts) do
    case Keyword.get(opts, :surface, :runtime) do
      :mix -> mix_script(command)
      _runtime -> runtime_script(command, program(opts))
    end
  end

  defp mix_script(:iperf3_baseline), do: "mix moqx.transport.iperf3_baseline"
  defp mix_script(:self_pair), do: "mix moqx.transport.self_pair"
  defp mix_script(:sender_admission), do: "mix moqx.transport.sender_admission"
  defp mix_script(:measure), do: "mix moqx.transport.measure"
  defp mix_script(:moqx_listener), do: "mix moqx.transport.moqx_listener"
  defp mix_script(:report), do: "mix moqx.transport.report"

  defp runtime_script(:iperf3_baseline, program), do: "#{program} iperf3-baseline"
  defp runtime_script(:self_pair, program), do: "#{program} self-pair"
  defp runtime_script(:sender_admission, program), do: "#{program} sender-admission"
  defp runtime_script(:measure, program), do: "#{program} measure"
  defp runtime_script(:moqx_listener, program), do: "#{program} moqx-listener"
  defp runtime_script(:report, program), do: "#{program} report"

  defp program(opts), do: Keyword.get(opts, :program, @runtime_program)
end
