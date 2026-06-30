defmodule MOQXProbe.HostSampler do
  @moduledoc """
  Out-of-band BEAM/host saturation sampler for the benchmark evidence contract.

  Implements the "Host and BEAM samples" evidence layer of
  ADR-0009 (`docs/adr/0009-layered-benchmark-evidence-contract.md`) under the
  handler discipline of ADR-0005.

  ## Observer-effect rules

  The sampler runs in its **own process**. It is never invoked from inside a
  `:telemetry` handler and never from inside the timed Benchee function. The
  caller starts it before the measured suite and stops it afterwards; sampling
  spans the run but all of its work happens in the sampler process, not in the
  hot path.

  Each sample is intentionally cheap and bounded: `:erlang.statistics/1`,
  `:scheduler.utilization/1` deltas across successive samples, and a bounded
  `Process.info/2` read for an explicit set of monitored role pids. The sampler
  never shells out on the sampling cadence.

  ## Inputs are explicit

  All inputs are passed as `start_link/1` arguments: the sampling interval, the
  output path, and the list of monitored sender-role `{label, pid}` entries.
  There is no `Application` environment configuration (CLAUDE.md hard rule).

  ## Sidecar shape

  Samples are written as a JSONL sidecar (`host-samples.jsonl`), one object per
  line, mirroring the `--evidence-output` delivery-evidence pattern. The first
  line is a header describing the sampler; subsequent lines are samples.

  Discipline (ADR-0009): utilization values are raw fractions in `[0, 1]`, queue
  lengths and mailbox depths are raw counts, every field is explicitly named,
  the sampler interval is recorded, and roles are referenced by stable string
  labels — never raw pids. No derived bandwidth/goodput and no high-cardinality
  per-event labels live here.
  """

  use GenServer

  @schema_version "moqxprobe-host-samples-v1"

  defmodule Role do
    @moduledoc false

    @enforce_keys [:label, :pid]
    defstruct [:label, :pid]

    @type t :: %__MODULE__{label: String.t(), pid: pid()}
  end

  defmodule State do
    @moduledoc false

    @enforce_keys [:interval_ms, :output, :roles, :started_mono_us]
    defstruct [
      :interval_ms,
      :output,
      :roles,
      :started_mono_us,
      :scheduler_wall_time_was_enabled?,
      :prev_scheduler_sample,
      :timer_ref,
      :file,
      sample_count: 0
    ]

    @type t :: %__MODULE__{}
  end

  @doc """
  Starts the sampler.

  Options:

    * `:interval_ms` (required, positive integer) — sampling cadence.
    * `:output` (required, path) — JSONL sidecar destination.
    * `:roles` (optional, default `[]`) — list of `{label, pid}` tuples or
      `%MOQXProbe.HostSampler.Role{}` structs naming the monitored sender-role
      processes. Labels must be stable strings; pids are never written.
    * `:name` (optional) — GenServer name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    gen_opts = if name = Keyword.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Stops the sampler, flushing the sidecar and restoring the prior
  `:scheduler_wall_time` system flag.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns the number of samples recorded so far. Test/diagnostic aid.
  """
  @spec sample_count(GenServer.server()) :: non_neg_integer()
  def sample_count(server) do
    GenServer.call(server, :sample_count)
  end

  @doc """
  Builds the normalized list of `Role` structs from caller input, dropping
  entries that are not live pids. Pure helper, exposed for testing.
  """
  @spec roles(Enumerable.t()) :: [Role.t()]
  def roles(entries) do
    entries
    |> Enum.map(&normalize_role/1)
    |> Enum.reject(&is_nil/1)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    interval_ms = fetch_positive_integer!(opts, :interval_ms)
    output = Keyword.fetch!(opts, :output)
    roles = roles(Keyword.get(opts, :roles, []))

    output |> Path.dirname() |> File.mkdir_p!()
    file = File.open!(output, [:write, :utf8])

    was_enabled? = enable_scheduler_wall_time()

    state = %State{
      interval_ms: interval_ms,
      output: output,
      roles: roles,
      started_mono_us: monotonic_us(),
      scheduler_wall_time_was_enabled?: was_enabled?,
      prev_scheduler_sample: scheduler_wall_time_sample(),
      file: file
    }

    write_header(state)
    {:ok, schedule_tick(state)}
  end

  @impl GenServer
  def handle_call(:sample_count, _from, state) do
    {:reply, state.sample_count, state}
  end

  @impl GenServer
  def handle_info(:sample, state) do
    {sample, state} = take_sample(state)
    write_line(state, sample)
    state = %{state | sample_count: state.sample_count + 1}
    {:noreply, schedule_tick(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    restore_scheduler_wall_time(state.scheduler_wall_time_was_enabled?)

    if state.file do
      File.close(state.file)
    end

    :ok
  end

  defp schedule_tick(state) do
    %{state | timer_ref: Process.send_after(self(), :sample, state.interval_ms)}
  end

  # Builds one bounded sample row. Kept cheap: cheap VM statistics, a scheduler
  # utilization delta against the previous sample, and a bounded Process.info/2
  # read per monitored role. Never shells out.
  defp take_sample(state) do
    current_scheduler_sample = scheduler_wall_time_sample()

    scheduler_utilization =
      scheduler_utilization(state.prev_scheduler_sample, current_scheduler_sample)

    run_queue_lengths = run_queue_lengths()

    sample = %{
      record_type: "host_sample",
      sample_index: state.sample_count,
      offset_ms: offset_ms(state.started_mono_us),
      sample_interval_ms: state.interval_ms,
      scheduler_utilization_fraction: scheduler_utilization.total,
      scheduler_utilization_weighted_fraction: scheduler_utilization.weighted,
      per_scheduler_utilization_fraction: scheduler_utilization.per_scheduler,
      total_run_queue_length: :erlang.statistics(:total_run_queue_lengths),
      per_run_queue_length: run_queue_lengths,
      total_active_tasks: :erlang.statistics(:total_active_tasks),
      schedulers_online: :erlang.system_info(:schedulers_online),
      process_count: :erlang.system_info(:process_count),
      run_queue: :erlang.statistics(:run_queue),
      roles: Enum.map(state.roles, &role_sample/1)
    }

    {sample, %{state | prev_scheduler_sample: current_scheduler_sample}}
  end

  # Bounded per-role read. nil-safe: a dead pid yields nil fields and an
  # alive?: false flag rather than crashing the sampler.
  defp role_sample(%Role{label: label, pid: pid}) do
    case Process.info(pid, [:message_queue_len, :reductions, :memory]) do
      [{:message_queue_len, mailbox}, {:reductions, reductions}, {:memory, memory}] ->
        %{
          role: label,
          alive?: true,
          message_queue_len: mailbox,
          reductions: reductions,
          memory_bytes: memory
        }

      nil ->
        %{
          role: label,
          alive?: false,
          message_queue_len: nil,
          reductions: nil,
          memory_bytes: nil
        }
    end
  end

  defp scheduler_wall_time_sample do
    :scheduler.sample_all()
  end

  # Translates two :scheduler.sample_all/0 snapshots into utilization fractions
  # in [0, 1] using :scheduler.utilization/2. The baseline snapshot is captured
  # in init/1, so the first emitted sample already carries utilization. The nil
  # clause is a guard for when no scheduler_wall_time baseline is available.
  defp scheduler_utilization(nil, _current), do: empty_scheduler_utilization()

  defp scheduler_utilization(previous, current) do
    util = :scheduler.utilization(previous, current)

    total = utilization_value(util, :total)
    weighted = utilization_value(util, :weighted)
    per_scheduler = normal_scheduler_utilizations(util)

    %{total: total, weighted: weighted, per_scheduler: per_scheduler}
  rescue
    _error -> empty_scheduler_utilization()
  catch
    _kind, _reason -> empty_scheduler_utilization()
  end

  defp empty_scheduler_utilization do
    %{total: nil, weighted: nil, per_scheduler: []}
  end

  defp utilization_value(util, kind) do
    Enum.find_value(util, fn
      {^kind, value, _percent} -> value
      _other -> nil
    end)
  end

  defp normal_scheduler_utilizations(util) do
    util
    |> Enum.filter(fn
      {:normal, _id, _value, _percent} -> true
      _other -> false
    end)
    |> Enum.map(fn {:normal, id, value, _percent} ->
      %{scheduler_id: id, utilization_fraction: value}
    end)
  end

  defp run_queue_lengths do
    :erlang.statistics(:run_queue_lengths)
  end

  defp enable_scheduler_wall_time do
    case :erlang.system_flag(:scheduler_wall_time, true) do
      previous when is_boolean(previous) -> previous
      _other -> false
    end
  end

  defp restore_scheduler_wall_time(previous) when is_boolean(previous) do
    _ = :erlang.system_flag(:scheduler_wall_time, previous)
    :ok
  end

  defp write_header(state) do
    header = %{
      schema_version: @schema_version,
      record_type: "header",
      sample_interval_ms: state.interval_ms,
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      roles: Enum.map(state.roles, & &1.label),
      otp_release: List.to_string(:erlang.system_info(:otp_release))
    }

    write_line(state, header)
  end

  defp write_line(state, record) do
    IO.write(state.file, JSON.encode!(record) <> "\n")
  end

  defp normalize_role(%Role{pid: pid} = role) when is_pid(pid) do
    if Process.alive?(pid), do: role, else: nil
  end

  defp normalize_role({label, pid}) when is_pid(pid) do
    normalize_role(%Role{label: to_string(label), pid: pid})
  end

  defp normalize_role(_other), do: nil

  defp fetch_positive_integer!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError, "#{inspect(key)} must be a positive integer, got #{inspect(value)}"
    end
  end

  defp offset_ms(started_mono_us) do
    div(monotonic_us() - started_mono_us, 1_000)
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)
end
