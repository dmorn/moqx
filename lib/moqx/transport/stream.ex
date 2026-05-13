defmodule MOQX.Transport.Stream do
  @moduledoc """
  Opaque stream handle returned by `MOQX.Transport`.
  """

  alias MOQX.Transport.{BackendRef, StreamInfo}

  @type t :: %__MODULE__{backend: BackendRef.t(), info: StreamInfo.t()}

  defstruct [:backend, :info]
end
