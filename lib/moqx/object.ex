defmodule MOQX.Object do
  @moduledoc """
  One protocol-neutral media object.

  Stream and object coordinates are shared by publication and subscription.
  `subscription` is populated on inbound delivery and remains `nil` for an
  outbound object supplied to a published track.
  """

  @enforce_keys [:group_id, :object_id, :payload]
  defstruct [
    :subscription,
    :group_id,
    :subgroup_id,
    :object_id,
    :publisher_priority,
    :status,
    :extensions,
    :end_of_group?,
    :payload
  ]

  @type t :: %__MODULE__{
          subscription: MOQX.Subscription.t() | nil,
          group_id: non_neg_integer(),
          subgroup_id: non_neg_integer() | nil,
          object_id: non_neg_integer(),
          publisher_priority: 0..255 | nil,
          status: :object_does_not_exist | :end_of_group | :end_of_track | nil,
          extensions: [MOQX.Extension.t()] | nil,
          end_of_group?: boolean() | nil,
          payload: binary()
        }
end
