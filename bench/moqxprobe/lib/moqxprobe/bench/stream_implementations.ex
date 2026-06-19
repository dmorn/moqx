defmodule MOQXProbe.Bench.StreamImplementations do
  @moduledoc false

  defstruct [
    :name,
    :label,
    :status,
    :summary,
    :architecture,
    :tested_bottleneck,
    :notes
  ]

  @type status :: :control | :historical | :current_best | :candidate

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t(),
          status: status(),
          summary: String.t(),
          architecture: String.t(),
          tested_bottleneck: String.t(),
          notes: [String.t()]
        }

  @spec all :: [t()]
  def all do
    [
      %__MODULE__{
        name: "context_owner",
        label: "Context-owned global sink",
        status: :control,
        summary: "single GenStage StreamSink owns all stream queues and completion state",
        architecture:
          "Flow source feeds one StreamSink; the benchmark process drains transport completions " <>
            "and updates the sink.",
        tested_bottleneck:
          "baseline cost of one process scanning all stream queues and windows on each send tick",
        notes: [
          "simple correctness control",
          "kept as a stable comparison point for global queue/window scanning costs"
        ]
      },
      %__MODULE__{
        name: "stream_owner",
        label: "One worker per stream",
        status: :historical,
        summary: "Flow-fed degenerate shard model with one sender worker per stream",
        architecture:
          "Flow source feeds a GenStage dispatcher that routes each payload event to its owning " <>
            "stream worker.",
        tested_bottleneck:
          "upper bound on per-stream process ownership overhead and worker receive-loop costs",
        notes: [
          "useful to compare against bounded shard counts",
          "not the current preferred process topology"
        ]
      },
      %__MODULE__{
        name: "sender_shards",
        label: "Bounded sender shards",
        status: :current_best,
        summary: "Flow-fed bounded worker set; each shard owns a subset of streams",
        architecture:
          "Flow source feeds a GenStage dispatcher that routes stream payload events to a " <>
            "configurable number of shard workers.",
        tested_bottleneck:
          "whether bounded parallel ownership beats both global queue scanning and one worker per stream",
        notes: [
          "current fake/local process-model winner",
          "shard count is intentionally tunable through --sender-shard-count"
        ]
      }
    ]
  end

  @spec names :: [String.t()]
  def names, do: Enum.map(all(), & &1.name)

  @spec current_best :: t()
  def current_best do
    Enum.find(all(), &(&1.status == :current_best))
  end

  @spec metadata(String.t()) :: map()
  def metadata(name) when is_binary(name) do
    implementation = fetch!(name)

    %{
      implementation_label: implementation.label,
      implementation_status: Atom.to_string(implementation.status),
      implementation_architecture: implementation.architecture,
      implementation_bottleneck: implementation.tested_bottleneck
    }
  end

  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(name) when is_binary(name) do
    Enum.find_value(all(), :error, fn
      %{name: ^name} = implementation -> {:ok, implementation}
      _implementation -> false
    end)
  end

  @spec fetch!(String.t()) :: t()
  def fetch!(name) when is_binary(name) do
    case fetch(name) do
      {:ok, implementation} -> implementation
      :error -> raise ArgumentError, "unknown stream implementation: #{name}"
    end
  end

  @spec help_names :: String.t()
  def help_names do
    all()
    |> Enum.map(& &1.name)
    |> case do
      [] -> ""
      [name] -> name
      [first, second] -> "#{first} or #{second}"
      names -> "#{Enum.drop(names, -1) |> Enum.join(", ")}, or #{List.last(names)}"
    end
  end

  @spec help_details :: String.t()
  def help_details do
    Enum.map_join(all(), "\n", fn implementation ->
      "      #{String.pad_trailing(implementation.name, 16)} " <>
        "#{implementation.status}: #{implementation.summary}"
    end)
  end
end
