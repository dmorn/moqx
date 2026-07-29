defmodule MOQX.PublishedSubscription do
  @moduledoc """
  Opaque handle for one accepted inbound publisher subscription.

  The handle belongs to the connection that accepted it. Applications can
  retain it and pass it back to MOQX without depending on protocol request
  identifiers.
  """

  @enforce_keys [:scope, :request_id]
  defstruct [:scope, :request_id]

  @opaque t :: %__MODULE__{scope: reference(), request_id: non_neg_integer()}
end

defimpl Inspect, for: MOQX.PublishedSubscription do
  def inspect(_subscription, _options), do: "#MOQX.PublishedSubscription<OPAQUE>"
end
