defmodule MOQXProbe.HostSamplerTest do
  use ExUnit.Case, async: false

  alias MOQXProbe.HostSampler

  @moduletag :tmp_dir

  defp idle_pid do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp read_samples(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp wait_for_samples(server, count, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_for_samples(server, count, deadline)
  end

  defp do_wait_for_samples(server, count, deadline) do
    cond do
      HostSampler.sample_count(server) >= count ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("sampler did not reach #{count} samples in time")

      true ->
        Process.sleep(5)
        do_wait_for_samples(server, count, deadline)
    end
  end

  test "produces well-formed samples for monitored pids", %{tmp_dir: tmp_dir} do
    output = Path.join(tmp_dir, "host-samples.jsonl")
    role_a = idle_pid()
    role_b = idle_pid()

    {:ok, sampler} =
      HostSampler.start_link(
        interval_ms: 10,
        output: output,
        roles: [{"sender_role_a", role_a}, {"sender_role_b", role_b}]
      )

    wait_for_samples(sampler, 2)
    HostSampler.stop(sampler)

    [header | samples] = read_samples(output)

    assert header["record_type"] == "header"
    assert header["schema_version"] == "moqxprobe-host-samples-v1"
    assert header["sample_interval_ms"] == 10
    assert header["roles"] == ["sender_role_a", "sender_role_b"]

    assert length(samples) >= 2

    for sample <- samples do
      assert sample["record_type"] == "host_sample"
      assert sample["sample_interval_ms"] == 10
      assert is_integer(sample["offset_ms"]) and sample["offset_ms"] >= 0
      assert is_integer(sample["total_run_queue_length"])
      assert is_list(sample["per_run_queue_length"])
      assert is_integer(sample["schedulers_online"])

      # Utilization fractions, when present, are raw fractions in [0, 1].
      case sample["scheduler_utilization_fraction"] do
        nil -> :ok
        value -> assert value >= 0.0 and value <= 1.0
      end

      roles = sample["roles"]
      assert length(roles) == 2
      labels = Enum.map(roles, & &1["role"])
      assert "sender_role_a" in labels
      assert "sender_role_b" in labels

      for role <- roles do
        assert role["alive?"] == true
        assert is_integer(role["message_queue_len"]) and role["message_queue_len"] >= 0
        assert is_integer(role["reductions"]) and role["reductions"] >= 0
        assert is_integer(role["memory_bytes"]) and role["memory_bytes"] > 0
      end
    end

    # No raw pids leak into the sidecar (ADR-0009 cardinality discipline).
    refute output |> File.read!() |> String.contains?("#PID")

    send(role_a, :stop)
    send(role_b, :stop)
  end

  test "handles monitored-pid death without crashing", %{tmp_dir: tmp_dir} do
    output = Path.join(tmp_dir, "host-samples.jsonl")
    role = idle_pid()

    {:ok, sampler} =
      HostSampler.start_link(
        interval_ms: 10,
        output: output,
        roles: [{"sender_role", role}]
      )

    # Kill the monitored pid after at least one sample, then keep sampling.
    wait_for_samples(sampler, 1)
    Process.exit(role, :kill)
    wait_for_samples(sampler, 4)

    assert Process.alive?(sampler)
    HostSampler.stop(sampler)

    [_header | samples] = read_samples(output)
    dead_samples = Enum.filter(samples, fn sample -> hd(sample["roles"])["alive?"] == false end)

    assert dead_samples != []

    for sample <- dead_samples do
      role = hd(sample["roles"])
      assert role["role"] == "sender_role"
      assert role["message_queue_len"] == nil
      assert role["reductions"] == nil
      assert role["memory_bytes"] == nil
    end
  end

  test "restores prior scheduler_wall_time flag on stop", %{tmp_dir: tmp_dir} do
    output = Path.join(tmp_dir, "host-samples.jsonl")
    original = :erlang.system_flag(:scheduler_wall_time, false)

    try do
      # Prior state disabled: the sampler enables it while running, then must
      # restore it to disabled on stop.
      run_and_assert_restore(output, false)

      # Prior state enabled: the sampler keeps it enabled on stop.
      run_and_assert_restore(output, true)
    after
      :erlang.system_flag(:scheduler_wall_time, original)
    end
  end

  defp run_and_assert_restore(output, prior_enabled?) do
    :erlang.system_flag(:scheduler_wall_time, prior_enabled?)

    {:ok, sampler} = HostSampler.start_link(interval_ms: 10, output: output, roles: [])
    wait_for_samples(sampler, 1)
    HostSampler.stop(sampler)

    # Reading the flag returns its current value (the prior the sampler
    # restored) without changing the observable answer for this assertion.
    assert :erlang.system_flag(:scheduler_wall_time, prior_enabled?) == prior_enabled?
  end

  test "drops non-pid and dead role entries", %{tmp_dir: tmp_dir} do
    output = Path.join(tmp_dir, "host-samples.jsonl")
    dead = idle_pid()
    Process.exit(dead, :kill)
    Process.sleep(10)
    alive = idle_pid()

    {:ok, sampler} =
      HostSampler.start_link(
        interval_ms: 10,
        output: output,
        roles: [{"alive", alive}, {"dead", dead}, {"bogus", :not_a_pid}]
      )

    wait_for_samples(sampler, 1)
    HostSampler.stop(sampler)

    [header | _samples] = read_samples(output)
    assert header["roles"] == ["alive"]

    send(alive, :stop)
  end

  test "rejects non-positive interval", %{tmp_dir: tmp_dir} do
    output = Path.join(tmp_dir, "host-samples.jsonl")
    Process.flag(:trap_exit, true)

    assert {:error, _reason} =
             HostSampler.start_link(interval_ms: 0, output: output, roles: [])
  end
end
