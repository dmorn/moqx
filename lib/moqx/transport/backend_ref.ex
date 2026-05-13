defmodule MOQX.Transport.BackendRef do
  @moduledoc """
  Opaque backend payload carried by transport contexts and handles.

  Protocol code may inspect `module` for diagnostics, but must treat `data` as
  backend-private.
  """

  @type t :: %__MODULE__{module: module(), data: term()}
  defstruct [:module, :data]
end
