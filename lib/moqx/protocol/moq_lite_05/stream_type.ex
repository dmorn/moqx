defmodule MOQX.Protocol.MOQLite05.StreamType do
  @moduledoc "Numeric stream type registry for MoQ Lite draft-05."

  @bidirectional %{
    0x1 => :announce,
    0x2 => :subscribe,
    0x3 => :fetch,
    0x4 => :probe,
    0x5 => :goaway,
    0x6 => :track
  }

  @unidirectional %{0x0 => :group, 0x1 => :setup}

  @spec bidirectional() :: %{non_neg_integer() => atom()}
  def bidirectional, do: @bidirectional

  @spec unidirectional() :: %{non_neg_integer() => atom()}
  def unidirectional, do: @unidirectional
end
