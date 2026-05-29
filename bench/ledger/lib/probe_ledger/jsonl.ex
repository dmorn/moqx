defmodule ProbeLedger.JSONL do
  @moduledoc false

  def read_file(path) do
    with {:ok, body} <- File.read(path) do
      parse(body)
    end
  end

  def parse(body) when is_binary(body) do
    {records, errors} =
      body
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, &parse_line/2)

    if errors == [] do
      {:ok, Enum.reverse(records)}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp parse_line({line, line_number}, {records, errors}) do
    case String.trim(line) do
      "" ->
        {records, errors}

      json ->
        case decode(json) do
          {:ok, record} -> {[record | records], errors}
          {:error, message} -> {records, [%{line: line_number, message: message} | errors]}
        end
    end
  end

  defp decode(json) do
    {:ok, :json.decode(json)}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end
end
