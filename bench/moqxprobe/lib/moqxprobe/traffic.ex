defmodule MOQXProbe.Traffic do
  @moduledoc false

  alias MOQXProbe.Traffic.PayloadFlow

  @type workload :: :datagram | :stream
  @type sink :: module()

  def feed_payloads(enumerable, sink, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    flow =
      PayloadFlow.from_enumerable(
        enumerable,
        Keyword.take(opts, [:mapper, :stages, :min_demand, :max_demand])
      )

    subscription_opts = Keyword.take(opts, [:min_demand, :max_demand])

    with {:ok, coordinator} <- Flow.into_stages(flow, [{sink, subscription_opts}]) do
      await_flow(coordinator, timeout)
    end
  end

  defp await_flow(coordinator, timeout) do
    ref = Process.monitor(coordinator)

    receive do
      {:DOWN, ^ref, :process, ^coordinator, reason} when reason in [:normal, :shutdown] ->
        :ok

      {:DOWN, ^ref, :process, ^coordinator, reason} ->
        {:error, {:flow_exit, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :flow_timeout}
    end
  end
end
