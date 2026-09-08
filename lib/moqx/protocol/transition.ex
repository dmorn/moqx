defmodule MOQX.Protocol.Transition do
  @moduledoc """
  One pure protocol transition returned to the connection runtime.

  Events are application-facing protocol events. Actions are requests for the
  runtime to operate on `MOQX.Transport`; they are data and are never applied
  by the protocol implementation itself.

  `attempt_actions/0` isolates one explicitly selected batch. Its actions still
  stop at the first failure, but the runtime feeds their result to the protocol
  before continuing the outer transition. Recovery is a protocol decision;
  this does not change the failure contract of ordinary actions.
  """

  @enforce_keys [:state]
  defstruct [:state, events: [], actions: []]

  @type attempt_actions :: {:attempt_actions, key :: term(), actions :: [term()]}

  @type t :: %__MODULE__{
          state: term(),
          events: [term()],
          actions: [term()]
        }

  @type result :: {:ok, t()} | {:error, term(), t()}

  @doc "Builds a successful transition."
  @spec ok(term(), keyword()) :: result()
  def ok(state, opts \\ []) do
    {:ok,
     %__MODULE__{
       state: state,
       events: Keyword.get(opts, :events, []),
       actions: Keyword.get(opts, :actions, [])
     }}
  end

  @doc "Builds a failed transition while retaining the updated protocol state and effects."
  @spec error(term(), term(), keyword()) :: result()
  def error(state, reason, opts \\ []) do
    {:error, reason,
     %__MODULE__{
       state: state,
       events: Keyword.get(opts, :events, []),
       actions: Keyword.get(opts, :actions, [])
     }}
  end
end
