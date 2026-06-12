defmodule MOQX.Transport.Conn do
  @moduledoc """
  Opaque QUIC connection handle returned by `MOQX.Transport`.
  """

  alias MOQX.Transport.BackendRef

  @type role :: :client | :server
  @type t :: %__MODULE__{backend: BackendRef.t(), local_role: role()}

  defstruct [:backend, :local_role]
end
