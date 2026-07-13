defmodule MOQX.Secret do
  @moduledoc """
  Explicit secret value whose inspection is always redacted.

  Secret acquisition and rotation stay outside MOQX. Callers resolve a value
  and pass this wrapper to the selected protocol implementation.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: binary()}

  @spec new(binary()) :: t()
  def new(value) when is_binary(value) and byte_size(value) > 0,
    do: %__MODULE__{value: value}

  @doc false
  @spec reveal(t()) :: binary()
  def reveal(%__MODULE__{value: value}), do: value
end

defimpl Inspect, for: MOQX.Secret do
  def inspect(_secret, _options), do: "#MOQX.Secret<REDACTED>"
end
