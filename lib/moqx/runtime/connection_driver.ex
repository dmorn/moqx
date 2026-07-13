defmodule MOQX.Runtime.ConnectionDriver do
  @moduledoc """
  Protocol-neutral owner of one transport connection and protocol state.

  The driver will resolve an explicitly selected `MOQX.Protocol`, own the
  `MOQX.Transport` context, feed normalized transport events and public
  operations into the implementation, apply returned transport actions, and
  publish returned events. The executable runtime is intentionally left for a
  later vertical slice; this module fixes the ownership boundary first.
  """
end
