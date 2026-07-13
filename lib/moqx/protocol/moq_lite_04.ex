defmodule MOQX.Protocol.MOQLite04 do
  @moduledoc """
  Target namespace for the MOQ Lite draft-04 protocol implementation.

  MOQ Lite owns its wire messages, codecs, and lifecycle because it does not
  use the MOQT draft-14 control-stream and object-delivery model. The existing
  `MOQX.MOQLite04` code remains migration input until it is routed through the
  common protocol and connection-driver boundaries.
  """
end

defmodule MOQX.Protocol.MOQLite04.Session do
  @moduledoc "Namespace for the MOQ Lite draft-04 lifecycle state machine."
end
