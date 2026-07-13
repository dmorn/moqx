defmodule MOQX.Publication do
  @moduledoc "Opaque handle for one protocol-neutral published namespace."

  @enforce_keys [:id, :namespace]
  defstruct [:id, :namespace]

  @opaque t :: %__MODULE__{id: non_neg_integer(), namespace: [binary()]}
end
