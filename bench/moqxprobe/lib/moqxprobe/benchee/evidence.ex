defmodule MOQXProbe.Benchee.Evidence do
  @moduledoc false

  alias MOQXProbe.Benchee.RunReceipt

  @enforce_keys [:receipt_id, :source, :status, :valid, :expected, :observed]
  defstruct [
    :receipt_id,
    :source,
    :status,
    :error,
    valid: false,
    expected: %{},
    observed: %{},
    mismatches: [],
    metadata: %{},
    collected_at: nil
  ]

  @type status :: :valid | :invalid | :timeout | :error

  @type t :: %__MODULE__{
          receipt_id: term(),
          source: atom() | String.t(),
          status: status(),
          valid: boolean(),
          expected: map(),
          observed: map(),
          mismatches: [map()],
          error: term(),
          metadata: map(),
          collected_at: DateTime.t() | nil
        }

  @spec from_observed(RunReceipt.t(), map(), keyword()) :: t()
  def from_observed(%RunReceipt{} = receipt, observed, opts \\ []) when is_map(observed) do
    expected = receipt.expected
    observed = normalize_map(observed)
    mismatches = mismatches(expected, observed)
    complete? = Keyword.get(opts, :complete?, true)
    valid? = complete? and mismatches == []

    %__MODULE__{
      receipt_id: receipt.id,
      source: Keyword.get(opts, :source, receipt.target),
      status: status(valid?),
      valid: valid?,
      expected: expected,
      observed: observed,
      mismatches: mismatches,
      error: Keyword.get(opts, :error),
      metadata: normalize_map(Keyword.get(opts, :metadata, %{})),
      collected_at: Keyword.get_lazy(opts, :collected_at, &DateTime.utc_now/0)
    }
  end

  @spec timeout(RunReceipt.t(), atom() | String.t(), non_neg_integer(), keyword()) :: t()
  def timeout(%RunReceipt{} = receipt, source, timeout_ms, opts \\ []) do
    %__MODULE__{
      receipt_id: receipt.id,
      source: source,
      status: :timeout,
      valid: false,
      expected: receipt.expected,
      observed: %{},
      mismatches: [],
      error: {:timeout, timeout_ms},
      metadata: normalize_map(Keyword.get(opts, :metadata, %{})),
      collected_at: Keyword.get_lazy(opts, :collected_at, &DateTime.utc_now/0)
    }
  end

  @spec error(RunReceipt.t(), atom() | String.t(), term(), keyword()) :: t()
  def error(%RunReceipt{} = receipt, source, reason, opts \\ []) do
    %__MODULE__{
      receipt_id: receipt.id,
      source: source,
      status: :error,
      valid: false,
      expected: receipt.expected,
      observed: %{},
      mismatches: [],
      error: reason,
      metadata: normalize_map(Keyword.get(opts, :metadata, %{})),
      collected_at: Keyword.get_lazy(opts, :collected_at, &DateTime.utc_now/0)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = evidence) do
    %{
      receipt_id: external_id(evidence.receipt_id),
      source: evidence.source,
      status: evidence.status,
      valid: evidence.valid,
      expected: encode_expected_map(evidence.expected),
      observed: evidence.observed,
      mismatches: evidence.mismatches,
      error: inspect_error(evidence.error),
      metadata: evidence.metadata,
      collected_at: format_time(evidence.collected_at)
    }
  end

  defp status(true), do: :valid
  defp status(false), do: :invalid

  defp mismatches(expected, observed) do
    expected
    |> Enum.reject(fn {key, expected_value} ->
      satisfied?(expected_value, Map.get(observed, key))
    end)
    |> Enum.map(fn {key, expected_value} ->
      %{
        field: key,
        expected: encode_expected(expected_value),
        observed: Map.get(observed, key)
      }
    end)
  end

  # An expectation is either an exact value (default, equality) or a tagged
  # lower-bound `{:at_least, min}`. The lower bound exists for the open-loop
  # paced sender (ADR-0009): the receiver keeps draining bytes after the sender
  # window closes, so observed receiver bytes must be at least the accepted
  # bytes, never exactly equal. Equality stays the default for closed-loop and
  # fake evidence so existing exact-count checks are unchanged.
  defp satisfied?({:at_least, min}, observed) when is_number(observed) and is_number(min) do
    observed >= min
  end

  defp satisfied?({:at_least, _min}, _observed), do: false
  defp satisfied?(expected_value, observed), do: observed == expected_value

  # Keep `expected` JSON-serializable in the sidecar: render the comparator as a
  # plain map instead of leaking an Elixir tuple into the encoder.
  defp encode_expected({:at_least, min}), do: %{comparator: "at_least", value: min}
  defp encode_expected(expected_value), do: expected_value

  @doc false
  @spec encode_expected_map(map()) :: map()
  def encode_expected_map(expected) when is_map(expected) do
    Map.new(expected, fn {key, value} -> {key, encode_expected(value)} end)
  end

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map

  defp inspect_error(nil), do: nil
  defp inspect_error(error), do: inspect(error)

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp format_time(time), do: time

  defp external_id(id) when is_binary(id), do: id
  defp external_id(id) when is_atom(id), do: Atom.to_string(id)
  defp external_id(id), do: inspect(id)
end
