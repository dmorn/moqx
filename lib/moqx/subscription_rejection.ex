defmodule MOQX.SubscriptionRejection do
  @moduledoc "Protocol-neutral reason for rejecting an inbound publisher subscription."

  @enforce_keys [:code]
  defstruct [:code, :reason]

  @type code ::
          :internal_error
          | :unauthorized
          | :timeout
          | :not_supported
          | :track_does_not_exist
          | :invalid_range
          | :malformed_auth_token
          | :expired_auth_token

  @type t :: %__MODULE__{code: code(), reason: binary() | nil}
end
