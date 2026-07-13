defmodule MOQX.Protocol.CloudflareDraft14 do
  @moduledoc """
  Cloudflare's deployed MOQT draft-14 protocol implementation namespace.

  This implementation composes `MOQX.Protocol.MOQTDraft14` wire machinery and
  owns Cloudflare-specific setup, supported operations, catalog conventions,
  authentication, lifecycle, events, and errors.
  """
end

defmodule MOQX.Protocol.CloudflareDraft14.Session do
  @moduledoc "Namespace for the Cloudflare draft-14 lifecycle state machine."
end
