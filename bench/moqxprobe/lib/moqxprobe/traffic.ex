defmodule MOQXProbe.Traffic do
  @moduledoc false

  alias MOQXProbe.Traffic.PayloadFlow

  @type workload :: :datagram | :stream
  @type sink :: module()

  def feed_payloads(enumerable, sink, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    with {:ok, coordinator} <- start_payloads(enumerable, sink, opts) do
      await_payloads(coordinator, timeout)
    end
  end

  def start_payloads(enumerable, sink, opts \\ []) do
    flow =
      PayloadFlow.from_enumerable(
        enumerable,
        Keyword.take(opts, [:mapper, :stages, :min_demand, :max_demand])
      )

    subscription_opts = Keyword.take(opts, [:min_demand, :max_demand])

    Flow.into_stages(flow, [{sink, subscription_opts}])
  end

  def await_payloads(coordinator, timeout) when is_pid(coordinator) do
    ref = Process.monitor(coordinator)

    receive do
      {:DOWN, ^ref, :process, ^coordinator, reason}
      when reason in [:normal, :shutdown, :noproc] ->
        :ok

      {:DOWN, ^ref, :process, ^coordinator, reason} ->
        {:error, {:flow_exit, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :flow_timeout}
    end
  end

  def stop_payloads(coordinator, timeout \\ 1_000) when is_pid(coordinator) do
    Process.unlink(coordinator)
    ref = Process.monitor(coordinator)
    Process.exit(coordinator, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^coordinator, _reason} ->
        :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(coordinator, :kill)
        :ok
    end
  end
end
