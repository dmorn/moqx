defmodule MOQX.Protocol.MOQTDraft14 do
  @moduledoc """
  Versioned reusable wire package for IETF MOQT draft-14.

  Standard message structs and payload/control/object/datagram codecs belong
  under this namespace. Relay-specific lifecycle and policy do not.
  """
end

defmodule MOQX.Protocol.MOQTDraft14.Messages do
  @moduledoc "Namespace for semantic IETF MOQT draft-14 wire message structs."
end

defmodule MOQX.Protocol.MOQTDraft14.Codec do
  @moduledoc "Namespace for IETF MOQT draft-14 wire codecs and framing state."
end
