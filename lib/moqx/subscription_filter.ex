defmodule MOQX.SubscriptionFilter do
  @moduledoc "Protocol-neutral object boundary requested for an inbound subscription."

  @enforce_keys [:type]
  defstruct [:type, :start_location, :end_group]

  @type location :: {non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          type: :next_group_start | :largest_object | :absolute_start | :absolute_range,
          start_location: location() | nil,
          end_group: non_neg_integer() | nil
        }
end
