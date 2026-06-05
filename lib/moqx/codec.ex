defmodule MOQX.Codec do
  @moduledoc """
  Shared codec namespace for MOQT-family protocol implementations.

  Protocol-specific modules own their wire formats. This namespace holds the
  generic encoder/decoder contracts and will host binary helpers shared by
  draft-14, MOQ Lite, and future protocol variants.
  """
end
