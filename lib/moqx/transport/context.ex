defmodule MOQX.Transport.Context do
  @moduledoc """
  Caller-owned immutable transport context.

  Thread latest context through all `MOQX.Transport` calls. Do not use stale
  copies concurrently.
  """

  alias MOQX.Transport.BackendRef

  @type t :: %__MODULE__{backend: BackendRef.t()}
  defstruct [:backend]
end
