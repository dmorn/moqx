defmodule MOQXProbe.Benchee.RunManifest do
  @moduledoc """
  Builds the per-run manifest that ties every artifact of one benchmark run
  together, per the "Run manifest and artifact layout" and "Experiment
  lifecycle" sections of ADR-0009
  (`docs/adr/0009-layered-benchmark-evidence-contract.md`).

  This module is PURE: it takes explicit inputs (run id, command, args, git
  SHA, versions, target, mode, tier, sidecar paths, clock/source notes) and
  returns a serializable map. It never shells out for git/time and never reads
  `Application` env (ADR-0009 forbids `Application` env as benchmark config).
  The caller script supplies the runtime values.

  Missing optional sidecars are recorded as an explicit `nil` (serialized to
  JSON `null`), never absent by omission, so a reader can distinguish "not
  produced" from "forgot to record".
  """

  @schema_version "moqxprobe-run-manifest-v1"

  @target_types ~w(fake loopback_quic remote_quic)a
  @modes ~w(closed_loop open_loop)a
  @tiers ~w(fake loopback_quic remote_quic_no_wire remote_quic_with_wire forensic)a

  # Canonical sidecar slots. Every slot is always present in the manifest; a
  # slot the run did not produce is recorded as nil (JSON null), per ADR-0009.
  @sidecar_keys ~w(
    manifest
    benchee
    delivery_evidence
    host_samples
    paced
    iperf3
    capture
    flamegraph
  )a

  @doc """
  The manifest schema version string.
  """
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc """
  The canonical sidecar slot keys. Every slot appears in the manifest's
  `sidecars` map; unproduced slots are explicit `nil`.
  """
  @spec sidecar_keys() :: [atom()]
  def sidecar_keys, do: @sidecar_keys

  @doc """
  The default confidence tier for a benchmark target, per ADR-0009: a fake
  target is process-model only (`"fake"`); any real transport target defaults
  to local QUIC calibration (`"loopback_quic"`) until a remote tier is chosen.
  """
  @spec default_tier(atom()) :: String.t()
  def default_tier(:fake), do: "fake"
  def default_tier(_target), do: "loopback_quic"

  @doc """
  Derives the manifest `target_type` from the benchmark target and its
  confidence tier (ADR-0009). A fake target is always `:fake`; a real
  transport target is `:loopback_quic` for fake/loopback tiers and
  `:remote_quic` once the tier declares a remote path.
  """
  @spec target_type(atom(), String.t()) :: :fake | :loopback_quic | :remote_quic
  def target_type(:fake, _tier), do: :fake
  def target_type(_target, tier) when tier in ~w(fake loopback_quic), do: :loopback_quic
  def target_type(_target, _tier), do: :remote_quic

  @doc """
  Builds the manifest map from explicit inputs.

  Required keys:

    * `:run_id` - stable run id (string)
    * `:command` - the command that launched the run (string)
    * `:args` - argument list (list of strings)
    * `:git_sha` - git SHA the run was built from (string)
    * `:target_type` - one of `:fake`, `:loopback_quic`, `:remote_quic`
    * `:mode` - one of `:closed_loop`, `:open_loop`
    * `:tier` - one of the ADR-0009 confidence tiers

  Optional keys (omitted keys default to a stable empty/nil shape):

    * `:versions` - map of project/tool versions (e.g. `moqx`, `moqxprobe`,
      `elixir`, `otp`, `quicprobe`/reference version when known). Unknown
      versions should be passed as `nil` rather than omitted.
    * `:target` - map of `host`/`quic_port`/etc.
    * `:client_implementation` - client implementation name (string) or nil
    * `:workload` - workload/profile map
    * `:sidecars` - map of sidecar slot -> path; missing slots become nil
    * `:clock_source_notes` - map of clock/source provenance notes
    * `:created_at` - ISO 8601 timestamp string supplied by the caller

  Raises `ArgumentError` on an unknown `:target_type`, `:mode`, or `:tier`, or
  on an unknown sidecar slot.
  """
  @spec build(keyword() | map()) :: map()
  def build(inputs) do
    inputs = Map.new(inputs)

    %{
      schema_version: @schema_version,
      run_id: fetch!(inputs, :run_id),
      created_at: Map.get(inputs, :created_at),
      command: fetch!(inputs, :command),
      args: Map.get(inputs, :args, []),
      git_sha: fetch!(inputs, :git_sha),
      versions: normalize_versions(Map.get(inputs, :versions, %{})),
      target_type: validate_target_type!(fetch!(inputs, :target_type)),
      mode: validate_mode!(fetch!(inputs, :mode)),
      tier: validate_tier!(fetch!(inputs, :tier)),
      target: Map.get(inputs, :target),
      client_implementation: Map.get(inputs, :client_implementation),
      workload: Map.get(inputs, :workload),
      sidecars: build_sidecars(Map.get(inputs, :sidecars, %{})),
      clock_source_notes: Map.get(inputs, :clock_source_notes)
    }
  end

  @doc """
  Serializes a manifest map to a JSON string.
  """
  @spec to_json(map()) :: String.t()
  def to_json(manifest) when is_map(manifest) do
    JSON.encode!(manifest)
  end

  @doc """
  Builds the manifest and writes it to `path` as `manifest.json`.

  Creates the parent directory if needed. Returns `:ok` or `{:error, reason}`.
  """
  @spec write(keyword() | map(), Path.t()) :: :ok | {:error, term()}
  def write(inputs, path) when is_binary(path) do
    json = inputs |> build() |> to_json()
    path |> Path.dirname() |> File.mkdir_p!()
    File.write(path, json <> "\n")
  end

  # --- internals -------------------------------------------------------------

  defp fetch!(inputs, key) do
    case Map.fetch(inputs, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "RunManifest.build/1 requires #{inspect(key)}"
    end
  end

  defp validate_target_type!(value) when value in @target_types, do: value

  defp validate_target_type!(value) do
    raise ArgumentError,
          "invalid target_type #{inspect(value)}; expected one of #{inspect(@target_types)}"
  end

  defp validate_mode!(value) when value in @modes, do: value

  defp validate_mode!(value) do
    raise ArgumentError, "invalid mode #{inspect(value)}; expected one of #{inspect(@modes)}"
  end

  defp validate_tier!(value) when value in @tiers, do: value

  defp validate_tier!(value) do
    raise ArgumentError, "invalid tier #{inspect(value)}; expected one of #{inspect(@tiers)}"
  end

  # Every canonical slot is present; unproduced slots are explicit nil.
  defp build_sidecars(supplied) when is_map(supplied) do
    supplied = Map.new(supplied)
    unknown = Map.keys(supplied) -- @sidecar_keys

    if unknown != [] do
      raise ArgumentError,
            "unknown sidecar slot(s) #{inspect(unknown)}; expected subset of #{inspect(@sidecar_keys)}"
    end

    Map.new(@sidecar_keys, fn key -> {key, Map.get(supplied, key)} end)
  end

  # Preserve the keys the caller passes; nil is kept explicitly so a reader can
  # tell "version unknown" from "field absent".
  defp normalize_versions(versions) when is_map(versions), do: Map.new(versions)
end
