# Benchmark run report generator (ADR-0009 report/derivation layer).
#
# Reads a run's manifest.json + the sidecars it references, derives the
# comparison-ready metrics via the pure MOQXProbe.Report module, writes
# report.md next to the manifest, and records the report path back in the
# manifest's `sidecars.report` slot.
#
# Usage (run from bench/moqxprobe):
#   mix run bench/report.exs -- --manifest results/<run>/manifest.json
#   mix run bench/report.exs -- --run-dir results/<run>
#
# Sidecar paths are read from the manifest as stored (relative to the working
# directory at generation time); run this from the same directory the run was
# launched from. This script only parses JSONL and writes files — all
# derivation lives in MOQXProbe.Report.

defmodule MOQXProbe.Bench.Report do
  @moduledoc false

  alias MOQXProbe.Benchee.RunMetadata
  alias MOQXProbe.Report

  @switches [help: :boolean, manifest: :string, run_dir: :string, output: :string]
  @aliases [h: :help]

  def main(argv \\ System.argv()) do
    {opts, _rest, _invalid} =
      OptionParser.parse(drop_mix_separator(argv), switches: @switches, aliases: @aliases)

    if opts[:help] do
      IO.puts(usage())
    else
      run(opts)
    end
  end

  defp run(opts) do
    manifest_path = manifest_path!(opts)
    manifest = manifest_path |> File.read!() |> JSON.decode!()
    sidecars = Map.get(manifest, "sidecars") || %{}

    inputs = %{
      manifest: manifest,
      delivery: load_jsonl(Map.get(sidecars, "delivery_evidence")),
      paced: load_paced(Map.get(sidecars, "paced")),
      host: load_host(Map.get(sidecars, "host_samples")),
      iperf3: load_iperf3(Map.get(sidecars, "iperf3"))
    }

    report = Report.build(inputs)
    markdown = Report.to_markdown(report)

    output = opts[:output] || Path.join(Path.dirname(manifest_path), "report.md")
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, markdown)

    # Reuse the defended sidecars map: put_in/3 would raise if "sidecars" were
    # absent or nil, which is exactly the case Map.get above tolerates.
    updated = Map.put(manifest, "sidecars", Map.put(sidecars, "report", output))
    File.write!(manifest_path, JSON.encode!(updated) <> "\n")

    IO.puts(
      "Wrote #{output} (#{length(report.metrics)} derived metrics, #{length(report.warnings)} warnings)"
    )

    Enum.each(report.warnings, &IO.puts("  ⚠️  #{&1}"))
  end

  defp manifest_path!(opts) do
    cond do
      is_binary(opts[:manifest]) -> opts[:manifest]
      is_binary(opts[:run_dir]) -> Path.join(opts[:run_dir], "manifest.json")
      true -> Mix.raise("--manifest PATH or --run-dir DIR is required")
    end
  end

  # --- sidecar loading -------------------------------------------------------

  defp load_jsonl(nil), do: []

  defp load_jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  # Paced sidecar: header line, tick lines, and a final summary line, keyed by
  # record_type. Returns nil when absent so the report omits sender metrics.
  defp load_paced(nil), do: nil

  defp load_paced(path) do
    records = load_jsonl(path)

    %{
      "header" => find_record(records, "header"),
      "ticks" => Enum.filter(records, &(Map.get(&1, "record_type") == "tick")),
      "summary" => find_record(records, "summary")
    }
  end

  defp load_host(nil), do: nil

  defp load_host(path) do
    records = load_jsonl(path)

    %{
      "header" => find_record(records, "header"),
      "samples" => Enum.filter(records, &(Map.get(&1, "record_type") == "host_sample"))
    }
  end

  # The manifest records one iperf3 sidecar path; RunMetadata parses it into a
  # protocol-tagged summary the report compares against.
  defp load_iperf3(nil), do: nil
  defp load_iperf3(path), do: RunMetadata.iperf3_summaries([path])

  defp find_record(records, type) do
    Enum.find(records, %{}, &(Map.get(&1, "record_type") == type))
  end

  defp drop_mix_separator(["--" | argv]), do: argv
  defp drop_mix_separator(argv), do: argv

  defp usage do
    """
    Usage:
      mix run bench/report.exs -- --manifest results/<run>/manifest.json
      mix run bench/report.exs -- --run-dir results/<run>

    Options:
      --manifest PATH   path to the run's manifest.json
      --run-dir DIR     run bundle directory containing manifest.json
      --output PATH     report output path (default: <manifest dir>/report.md)
      -h, --help        show this help

    Reads the sidecars the manifest references, derives ADR-0009 metrics via
    MOQXProbe.Report, writes report.md, and links it in the manifest.
    """
  end
end

MOQXProbe.Bench.Report.main()
