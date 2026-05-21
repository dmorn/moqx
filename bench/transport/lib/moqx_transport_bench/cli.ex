defmodule MOQX.TransportBench.CLI do
  @moduledoc false

  alias MOQX.TransportBench.Iperf3Baseline
  alias MOQX.TransportBench.QuicerSelfPair
  alias MOQX.TransportBench.ReferenceComparison
  alias MOQX.TransportBench.ReportCommand

  @runtime_program "moqx-transport-bench"

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
      reference-comparison
                        Run selected reference QUIC comparison benchmarks
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

  defp dispatch(command, argv, opts)
       when command in ["reference-comparison", "reference_comparison"] do
    ReferenceComparison.main(argv, script: command_script(:reference_comparison, opts))
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
  defp mix_script(:reference_comparison), do: "mix moqx.transport.reference_comparison"
  defp mix_script(:report), do: "mix moqx.transport.report"

  defp runtime_script(:iperf3_baseline, program), do: "#{program} iperf3-baseline"
  defp runtime_script(:self_pair, program), do: "#{program} self-pair"
  defp runtime_script(:reference_comparison, program), do: "#{program} reference-comparison"
  defp runtime_script(:report, program), do: "#{program} report"

  defp program(opts), do: Keyword.get(opts, :program, @runtime_program)
end
