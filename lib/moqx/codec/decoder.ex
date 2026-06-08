defmodule MOQX.Codec.Decoder do
  @moduledoc """
  Behaviour for decoding complete payload binaries.

  A decoder receives a complete payload binary for a known value shape and
  returns the corresponding typed value. Protocol-specific stream codecs are
  responsible for reading stream type prefixes, stripping payload-size fields,
  managing buffers, and selecting the decoder according to stream state.
  """

  @type t :: module()
  @type context :: %{optional(atom()) => term()}
  @type result :: term()

  @callback decode(binary(), context()) :: {:ok, result()} | {:error, term()}
end
