defmodule MOQX.Object do
  @moduledoc """
  One protocol-neutral media object delivered for a subscription.

  Stream and object coordinates are preserved so callers can order, deduplicate
  and inspect delivery without depending on wire-specific message structs.
  """

  @enforce_keys [:subscription, :group_id, :object_id, :payload]
  defstruct [
    :subscription,
    :group_id,
    :subgroup_id,
    :object_id,
    :publisher_priority,
    :status,
    :payload
  ]

  @type t :: %__MODULE__{
          subscription: MOQX.Subscription.t(),
          group_id: non_neg_integer(),
          subgroup_id: non_neg_integer() | nil,
          object_id: non_neg_integer(),
          publisher_priority: 0..255,
          status: :object_does_not_exist | :end_of_group | :end_of_track | nil,
          payload: binary()
        }
end
