defmodule MOQX.Protocol do
  @moduledoc """
  Contract between the protocol-neutral connection runtime and one concrete
  MOQT-family protocol implementation.

  Implementations own their wire messages, codecs, lifecycle, capabilities,
  commands, events, and error semantics. The runtime owns the
  `MOQX.Transport` context and applies the transport actions returned in
  `MOQX.Protocol.Transition` values.
  """

  alias MOQX.Protocol.{Capabilities, Transition, TransportSpec}

  @type id :: :cloudflare_draft_14
  @type state :: term()

  @callback id() :: id() | atom()

  @callback transport_spec(endpoint :: URI.t(), options :: keyword()) ::
              {:ok, TransportSpec.t()} | {:error, term()}

  @callback init(endpoint :: URI.t(), options :: keyword()) ::
              {:ok, state()} | {:error, term()}

  @callback handle_operation(state(), MOQX.Operation.t()) :: Transition.result()

  @type runtime_event :: {:runtime_timeout, term()}

  @callback handle_transport(state(), MOQX.Transport.event() | runtime_event()) ::
              Transition.result()

  @callback capabilities(state()) :: Capabilities.t()

  @doc "Returns whether a module exports the complete protocol implementation contract."
  @spec implementation?(module()) :: boolean()
  def implementation?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(
        [
          {:id, 0},
          {:transport_spec, 2},
          {:init, 2},
          {:handle_operation, 2},
          {:handle_transport, 2},
          {:capabilities, 1}
        ],
        fn {function, arity} -> function_exported?(module, function, arity) end
      )
  end
end
