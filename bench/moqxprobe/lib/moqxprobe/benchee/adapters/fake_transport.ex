defmodule MOQXProbe.Benchee.Adapters.FakeTransport do
  @moduledoc false

  @behaviour MOQXProbe.Benchee.EvidenceAdapter

  alias MOQXProbe.Benchee.Evidence
  alias MOQXProbe.Benchee.RunReceipt

  @impl true
  def collect(%RunReceipt{} = receipt, opts) do
    with {:ok, source} <- fetch_source(opts),
         {:ok, observed} <- read_source(source, receipt) do
      {:ok,
       Evidence.from_observed(receipt, observed,
         source: :fake_transport,
         metadata: %{target: receipt.target}
       )}
    end
  end

  defp fetch_source(opts) do
    case {Keyword.fetch(opts, :source), Keyword.fetch(opts, :state)} do
      {{:ok, source}, _state} -> {:ok, source}
      {:error, {:ok, state}} -> {:ok, state}
      {:error, :error} -> {:error, :missing_fake_transport_source}
    end
  end

  defp read_source(source, _receipt) when is_function(source, 0), do: {:ok, source.()}
  defp read_source(source, receipt) when is_function(source, 1), do: {:ok, source.(receipt)}

  defp read_source(source, %RunReceipt{id: id}) when is_map(source) do
    {:ok, Map.get(source, id, Map.get(source, inspect(id), source))}
  end

  defp read_source(_source, _receipt), do: {:error, :unsupported_fake_transport_source}
end
