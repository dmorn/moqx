defmodule MOQXProbe.ReportCommand do
  @moduledoc false

  alias MOQXProbe.Report
  alias ProbeLedger.Contract
  alias ProbeLedger.JSONL

  @default_script "moqxprobe report"

  def main(argv, opts \\ []) do
    script = Keyword.get(opts, :script, @default_script)

    case parse(argv, script) do
      {:help, message} ->
        IO.puts(message)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(2)

      {:ok, config} ->
        render(config)
    end
  end

  defp parse(argv, script) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          format: :string,
          strict: :boolean,
          help: :boolean
        ],
        aliases: [
          h: :help
        ]
      )

    cond do
      opts[:help] ->
        {:help, usage(script)}

      invalid != [] ->
        {:error, "Invalid options: #{inspect(invalid)}\n\n#{usage(script)}"}

      length(args) != 1 ->
        {:error, "Expected exactly one JSONL path.\n\n#{usage(script)}"}

      Keyword.get(opts, :format, "text") not in ["text", "markdown"] ->
        {:error, "--format must be text or markdown.\n\n#{usage(script)}"}

      true ->
        {:ok,
         %{
           path: List.first(args),
           format: Keyword.get(opts, :format, "text"),
           strict?: Keyword.get(opts, :strict, false)
         }}
    end
  end

  defp render(config) do
    case JSONL.read_file(config.path) do
      {:ok, records} ->
        validation = Contract.validate_records(records)
        IO.puts(Report.render(records, format: config.format, validation: validation))

        if config.strict? && !validation.valid? do
          System.halt(1)
        end

      {:error, errors} when is_list(errors) ->
        Enum.each(errors, fn error ->
          IO.puts(:stderr, "line #{error.line}: #{error.message}")
        end)

        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, to_string(reason))
        System.halt(1)
    end
  end

  defp usage(script) do
    """
    Usage:
      #{script} PATH [options]

    Options:
      --format FORMAT      text or markdown (default: text)
      --strict             exit non-zero when the JSONL violates the contract
      --help               show this help
    """
  end
end
