defmodule MOQX.Client do
  @moduledoc "Opaque handle for a process-owned MOQX connection."

  @enforce_keys [:pid, :protocol]
  defstruct [:pid, :protocol]

  @opaque t :: %__MODULE__{pid: pid(), protocol: atom()}
end
