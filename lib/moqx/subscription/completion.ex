defmodule MOQX.Subscription.Completion do
  @moduledoc "The terminal result of a remote subscription."

  @enforce_keys [:status, :status_code, :reason, :expected_streams, :processed_streams]
  defstruct [
    :status,
    :status_code,
    :reason,
    :expected_streams,
    :processed_streams,
    timed_out?: false
  ]

  @type status ::
          :internal_error
          | :unauthorized
          | :track_ended
          | :subscription_ended
          | :going_away
          | :expired
          | :too_far_behind
          | :malformed_track
          | {:unknown, non_neg_integer()}

  @type t :: %__MODULE__{
          status: status(),
          status_code: non_neg_integer(),
          reason: binary(),
          expected_streams: non_neg_integer() | :unknown,
          processed_streams: non_neg_integer(),
          timed_out?: boolean()
        }
end
