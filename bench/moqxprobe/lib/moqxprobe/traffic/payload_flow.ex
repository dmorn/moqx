defmodule MOQXProbe.Traffic.PayloadFlow do
  @moduledoc false

  def from_enumerable(enumerable, opts \\ []) do
    mapper = Keyword.get(opts, :mapper, & &1)

    enumerable
    |> Flow.from_enumerable(flow_opts(opts))
    |> Flow.map(mapper)
  end

  defp flow_opts(opts) do
    opts
    |> Keyword.take([:stages, :min_demand, :max_demand])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
