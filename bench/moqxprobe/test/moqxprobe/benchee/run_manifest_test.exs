defmodule MOQXProbe.Benchee.RunManifestTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Benchee.RunManifest

  defp inputs(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: "20260630T120000-1",
        command: "mix run bench/stream_clients.exs",
        args: ["--target", "fake", "--stream-count", "32"],
        git_sha: "deadbee",
        target_type: :fake,
        mode: :closed_loop,
        tier: :fake
      },
      overrides
    )
  end

  test "builds a manifest from explicit inputs" do
    manifest = RunManifest.build(inputs())

    assert manifest.run_id == "20260630T120000-1"
    assert manifest.command == "mix run bench/stream_clients.exs"
    assert manifest.args == ["--target", "fake", "--stream-count", "32"]
    assert manifest.git_sha == "deadbee"
    assert manifest.target_type == :fake
    assert manifest.mode == :closed_loop
    assert manifest.tier == :fake
  end

  test "includes the schema_version" do
    assert RunManifest.build(inputs()).schema_version == "moqxprobe-run-manifest-v1"
    assert RunManifest.schema_version() == "moqxprobe-run-manifest-v1"
  end

  test "captures target type, mode, and tier" do
    manifest =
      RunManifest.build(
        inputs(%{target_type: :remote_quic, mode: :open_loop, tier: :remote_quic_with_wire})
      )

    assert manifest.target_type == :remote_quic
    assert manifest.mode == :open_loop
    assert manifest.tier == :remote_quic_with_wire
  end

  test "records project/tool versions and target metadata" do
    manifest =
      RunManifest.build(
        inputs(%{
          versions: %{
            moqx: "0.7.1",
            moqxprobe: "0.1.0",
            elixir: "1.19.0",
            otp: "27",
            quicprobe: nil
          },
          target: %{host: "100.64.0.1", quic_port: 4433},
          client_implementation: "flow_partitions",
          workload: %{profile: "draft14_object_stream", stream_count: 32}
        })
      )

    assert manifest.versions.moqx == "0.7.1"
    assert manifest.versions.moqxprobe == "0.1.0"
    assert manifest.versions.elixir == "1.19.0"
    assert manifest.versions.otp == "27"
    # Unknown version is explicit nil, not absent.
    assert Map.has_key?(manifest.versions, :quicprobe)
    assert manifest.versions.quicprobe == nil
    assert manifest.target == %{host: "100.64.0.1", quic_port: 4433}
    assert manifest.client_implementation == "flow_partitions"
    assert manifest.workload == %{profile: "draft14_object_stream", stream_count: 32}
  end

  test "missing optional sidecars are explicit nil, not absent by omission" do
    manifest =
      RunManifest.build(
        inputs(%{
          sidecars: %{
            benchee: "results/run/benchee.json",
            delivery_evidence: "results/run/delivery-evidence.jsonl"
          }
        })
      )

    # Every canonical slot is present in the map.
    for key <- RunManifest.sidecar_keys() do
      assert Map.has_key?(manifest.sidecars, key),
             "expected sidecar slot #{inspect(key)} to be present"
    end

    assert manifest.sidecars.benchee == "results/run/benchee.json"
    assert manifest.sidecars.delivery_evidence == "results/run/delivery-evidence.jsonl"
    # Unproduced sidecars are explicit nil.
    assert manifest.sidecars.host_samples == nil
    assert manifest.sidecars.paced == nil
    assert manifest.sidecars.iperf3 == nil
    assert manifest.sidecars.capture == nil
    assert manifest.sidecars.flamegraph == nil
  end

  test "rejects unknown sidecar slots" do
    assert_raise ArgumentError, ~r/unknown sidecar slot/, fn ->
      RunManifest.build(inputs(%{sidecars: %{not_a_slot: "x"}}))
    end
  end

  test "rejects invalid target type, mode, and tier" do
    assert_raise ArgumentError, ~r/invalid target_type/, fn ->
      RunManifest.build(inputs(%{target_type: :bogus}))
    end

    assert_raise ArgumentError, ~r/invalid mode/, fn ->
      RunManifest.build(inputs(%{mode: :half_loop}))
    end

    assert_raise ArgumentError, ~r/invalid tier/, fn ->
      RunManifest.build(inputs(%{tier: :super}))
    end
  end

  test "requires the mandatory inputs" do
    assert_raise ArgumentError, ~r/requires :run_id/, fn ->
      RunManifest.build(Map.delete(inputs(), :run_id))
    end

    assert_raise ArgumentError, ~r/requires :git_sha/, fn ->
      RunManifest.build(Map.delete(inputs(), :git_sha))
    end
  end

  test "JSON round-trips and preserves the contract fields" do
    manifest =
      RunManifest.build(
        inputs(%{
          created_at: "2026-06-30T12:00:00Z",
          versions: %{moqx: "0.7.1", quicprobe: nil},
          target: %{host: "127.0.0.1", quic_port: 4433},
          client_implementation: "sender_shards",
          workload: %{profile: "draft14_object_stream"},
          sidecars: %{benchee: "results/run/benchee.json"},
          clock_source_notes: %{monotonic: "System.monotonic_time/1"}
        })
      )

    decoded = manifest |> RunManifest.to_json() |> JSON.decode!()

    assert decoded["schema_version"] == "moqxprobe-run-manifest-v1"
    assert decoded["run_id"] == "20260630T120000-1"
    assert decoded["created_at"] == "2026-06-30T12:00:00Z"
    assert decoded["git_sha"] == "deadbee"
    # Atom enums serialize to their string form and survive the round trip.
    assert decoded["target_type"] == "fake"
    assert decoded["mode"] == "closed_loop"
    assert decoded["tier"] == "fake"
    assert decoded["client_implementation"] == "sender_shards"
    assert decoded["versions"]["moqx"] == "0.7.1"
    # Explicit-null version survives the round trip.
    assert Map.has_key?(decoded["versions"], "quicprobe")
    assert decoded["versions"]["quicprobe"] == nil
    assert decoded["sidecars"]["benchee"] == "results/run/benchee.json"
    # Explicit-null sidecar survives the round trip.
    assert Map.has_key?(decoded["sidecars"], "host_samples")
    assert decoded["sidecars"]["host_samples"] == nil
    assert decoded["clock_source_notes"]["monotonic"] == "System.monotonic_time/1"
  end

  test "write/2 serializes manifest.json to disk" do
    dir = Path.join(System.tmp_dir!(), "run-manifest-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "manifest.json")

    on_exit(fn -> File.rm_rf(dir) end)

    assert :ok = RunManifest.write(inputs(%{sidecars: %{paced: "results/run/paced.jsonl"}}), path)

    decoded = path |> File.read!() |> JSON.decode!()
    assert decoded["run_id"] == "20260630T120000-1"
    assert decoded["sidecars"]["paced"] == "results/run/paced.jsonl"
    assert decoded["sidecars"]["benchee"] == nil
  end
end
