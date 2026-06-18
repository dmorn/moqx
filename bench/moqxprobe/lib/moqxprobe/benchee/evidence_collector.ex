defmodule MOQXProbe.Benchee.EvidenceCollector do
  @moduledoc false

  alias MOQXProbe.Benchee.Evidence
  alias MOQXProbe.Benchee.RunReceipt

  defstruct [:table, :owner, :run_id]

  @type t :: %__MODULE__{table: :ets.tid(), owner: pid(), run_id: term()}

  @spec start(keyword()) :: {:ok, t()}
  def start(opts \\ []) do
    table =
      :ets.new(__MODULE__, [
        :set,
        :public,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    {:ok,
     %__MODULE__{table: table, owner: self(), run_id: Keyword.get(opts, :run_id, make_ref())}}
  end

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{table: table}) do
    if :ets.info(table) != :undefined do
      :ets.delete(table)
    end

    :ok
  end

  @spec put_receipt(t(), RunReceipt.t()) :: :ok
  def put_receipt(%__MODULE__{} = collector, %RunReceipt{} = receipt) do
    true = :ets.insert(collector.table, {{:receipt, receipt.id}, receipt})
    :ok
  end

  @spec attach_evidence(t(), RunReceipt.t() | term(), Evidence.t()) :: :ok
  def attach_evidence(%__MODULE__{} = collector, %RunReceipt{id: id}, %Evidence{} = evidence) do
    attach_evidence(collector, id, evidence)
  end

  def attach_evidence(%__MODULE__{} = collector, receipt_id, %Evidence{} = evidence) do
    true = :ets.insert(collector.table, {{:evidence, receipt_id}, evidence})
    :ok
  end

  @spec record_error(t(), RunReceipt.t(), term(), keyword()) :: :ok
  def record_error(%__MODULE__{} = collector, %RunReceipt{} = receipt, reason, opts \\ []) do
    evidence = Evidence.error(receipt, Keyword.get(opts, :source, receipt.target), reason, opts)
    put_receipt(collector, receipt)
    attach_evidence(collector, receipt, evidence)
  end

  @spec collect(t(), module(), RunReceipt.t(), keyword()) ::
          {:ok, Evidence.t()} | {:error, term()}
  def collect(%__MODULE__{} = collector, adapter, %RunReceipt{} = receipt, opts \\ []) do
    put_receipt(collector, receipt)

    case adapter.collect(receipt, opts) do
      {:ok, %Evidence{} = evidence} ->
        attach_evidence(collector, receipt, evidence)
        {:ok, evidence}

      {:error, reason} ->
        evidence = Evidence.error(receipt, receipt.target, reason)
        attach_evidence(collector, receipt, evidence)
        {:error, reason}
    end
  end

  @spec after_each(t(), module(), keyword()) :: (term() -> term())
  def after_each(%__MODULE__{} = collector, adapter, opts \\ []) do
    fn
      %RunReceipt{} = receipt ->
        _ = collect(collector, adapter, receipt, opts)
        receipt

      other ->
        other
    end
  end

  @spec records(t()) :: [map()]
  def records(%__MODULE__{} = collector) do
    collector.table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, &merge_record/2)
    |> Map.values()
    |> Enum.sort_by(fn record -> inspect(record.receipt && record.receipt.id) end)
  end

  @spec sidecar_records(t()) :: [map()]
  def sidecar_records(%__MODULE__{} = collector) do
    Enum.map(records(collector), fn %{receipt: receipt, evidence: evidence} ->
      %{
        schema_version: "moqxprobe-benchee-evidence-v1",
        record_type: "delivery_evidence",
        run_id: external_id(collector.run_id),
        receipt: receipt && RunReceipt.to_map(receipt),
        evidence: evidence && Evidence.to_map(evidence)
      }
    end)
  end

  @spec write_jsonl(t(), Path.t()) :: :ok | {:error, term()}
  def write_jsonl(%__MODULE__{} = collector, path) do
    content =
      collector
      |> sidecar_records()
      |> Enum.map_join("", fn record -> json_encode!(record) <> "\n" end)

    File.write(path, content)
  end

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = collector) do
    statuses =
      collector
      |> records()
      |> Enum.map(fn
        %{evidence: %Evidence{status: status}} -> status
        %{evidence: nil} -> :missing
      end)
      |> Enum.frequencies()

    %{
      total: Enum.sum(Map.values(statuses)),
      valid: Map.get(statuses, :valid, 0),
      invalid: Map.get(statuses, :invalid, 0),
      timeout: Map.get(statuses, :timeout, 0),
      error: Map.get(statuses, :error, 0),
      missing: Map.get(statuses, :missing, 0)
    }
  end

  defp merge_record({{:receipt, id}, receipt}, acc) do
    Map.update(acc, id, %{receipt: receipt, evidence: nil}, &Map.put(&1, :receipt, receipt))
  end

  defp merge_record({{:evidence, id}, evidence}, acc) do
    Map.update(acc, id, %{receipt: nil, evidence: evidence}, &Map.put(&1, :evidence, evidence))
  end

  defp json_encode!(record), do: JSON.encode!(record)

  defp external_id(id) when is_binary(id), do: id
  defp external_id(id) when is_atom(id), do: Atom.to_string(id)
  defp external_id(id), do: inspect(id)
end
