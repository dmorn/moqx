defmodule MOQX.Protocol.TransportSpec do
  @moduledoc """
  Transport requirements selected by a concrete protocol implementation.

  The connection runtime translates this value into calls to
  `MOQX.Transport`; the transport layer does not interpret protocol names.
  """

  @enforce_keys [:alpn]
  defstruct [:alpn, connect_options: [], required_capabilities: MapSet.new()]

  @type t :: %__MODULE__{
          alpn: binary(),
          connect_options: keyword(),
          required_capabilities: MapSet.t(atom())
        }
end
