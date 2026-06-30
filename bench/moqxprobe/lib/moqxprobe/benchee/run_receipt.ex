defmodule MOQXProbe.Benchee.RunReceipt do
  @moduledoc false

  alias MOQXProbe.Benchee.Evidence

  @enforce_keys [:id, :target, :expected]
  defstruct [
    :id,
    :target,
    :scenario,
    :input,
    :implementation,
    expected: %{},
    match: %{},
    metadata: %{},
    started_at: nil,
    finished_at: nil
  ]

  @type t :: %__MODULE__{
          id: term(),
          target: atom() | String.t(),
          scenario: atom() | String.t() | nil,
          input: atom() | String.t() | nil,
          implementation: atom() | String.t() | nil,
          expected: map(),
          match: map(),
          metadata: map(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

  def new!(attrs) when is_map(attrs) do
    expected = Map.get(attrs, :expected, Map.get(attrs, "expected", %{}))
    target = Map.get(attrs, :target, Map.get(attrs, "target"))

    %__MODULE__{
      id: Map.get(attrs, :id, Map.get(attrs, "id", make_ref())),
      target: target || raise(ArgumentError, "run receipt requires :target"),
      scenario: Map.get(attrs, :scenario, Map.get(attrs, "scenario")),
      input: Map.get(attrs, :input, Map.get(attrs, "input")),
      implementation: Map.get(attrs, :implementation, Map.get(attrs, "implementation")),
      expected: normalize_map(expected),
      match: normalize_map(Map.get(attrs, :match, Map.get(attrs, "match", %{}))),
      metadata: normalize_map(Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))),
      started_at: Map.get(attrs, :started_at, Map.get(attrs, "started_at")),
      finished_at: Map.get(attrs, :finished_at, Map.get(attrs, "finished_at"))
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = receipt) do
    %{
      id: external_id(receipt.id),
      target: receipt.target,
      scenario: receipt.scenario,
      input: receipt.input,
      implementation: receipt.implementation,
      expected: Evidence.encode_expected_map(receipt.expected),
      match: receipt.match,
      metadata: receipt.metadata,
      started_at: format_time(receipt.started_at),
      finished_at: format_time(receipt.finished_at)
    }
  end

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp format_time(time), do: time

  defp external_id(id) when is_binary(id), do: id
  defp external_id(id) when is_atom(id), do: Atom.to_string(id)
  defp external_id(id), do: inspect(id)
end
