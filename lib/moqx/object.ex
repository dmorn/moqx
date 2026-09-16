defmodule MOQX.Object do
  @moduledoc """
  One protocol-neutral media object.

  Stream and object coordinates are shared by publication and subscription.
  `timestamp` is an independent value expressed in the published track's
  timescale; protocols without timestamps leave it `nil`.
  `first_object?` records protocol provenance when the sender can signal that
  this is the first object ever published in its subgroup; `nil` leaves any
  inference to the selected protocol.
  `subscription` is populated on inbound delivery and remains `nil` for an
  outbound object supplied to a published track.
  """

  @enforce_keys [:group_id, :object_id, :payload]
  defstruct [
    :subscription,
    :group_id,
    :subgroup_id,
    :object_id,
    :timestamp,
    :publisher_priority,
    :first_object?,
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
          timestamp: non_neg_integer() | nil,
          publisher_priority: 0..255 | nil,
          first_object?: boolean() | nil,
          status: :object_does_not_exist | :end_of_group | :end_of_track | nil,
          extensions: [MOQX.Extension.t()] | nil,
          end_of_group?: boolean() | nil,
          payload: binary()
        }
end
