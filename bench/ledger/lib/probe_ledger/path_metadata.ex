defmodule ProbeLedger.PathMetadata do
  @moduledoc false

  def load_json!(source) when is_binary(source) do
    source
    |> json_source!()
    |> :json.decode()
    |> unwrap()
  end

  defp json_source!(source) do
    trimmed = String.trim(source)

    if String.starts_with?(trimmed, "{") do
      trimmed
    else
      File.read!(source)
    end
  end

  defp unwrap(%{"path" => path}), do: path
  defp unwrap(%{"value" => value}) when is_map(value), do: unwrap(value)
  defp unwrap(path) when is_map(path), do: path
end
