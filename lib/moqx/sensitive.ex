defmodule MOQX.Sensitive do
  @moduledoc false

  @enforce_keys [:data]
  defstruct [:data]

  @opaque t :: %__MODULE__{data: binary()}

  @spec new(binary()) :: t()
  def new(data) when is_binary(data), do: %__MODULE__{data: data}

  @doc false
  @spec reveal(t()) :: binary()
  def reveal(%__MODULE__{data: data}), do: data
end

defimpl Inspect, for: MOQX.Sensitive do
  def inspect(_sensitive, _options), do: "#MOQX.Sensitive<REDACTED>"
end
