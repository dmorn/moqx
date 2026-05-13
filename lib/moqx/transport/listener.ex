defmodule MOQX.Transport.Listener do
  @moduledoc """
  Opaque listener handle returned by `MOQX.Transport.listen/3`.
  """

  alias MOQX.Transport.BackendRef

  @type t :: %__MODULE__{
          backend: BackendRef.t(),
          local_role: :server,
          port: non_neg_integer() | nil
        }

  defstruct [:backend, :local_role, :port]
end
