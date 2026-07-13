defmodule MOQX.Operation do
  @moduledoc """
  Protocol-neutral application intent accepted by a protocol implementation.

  Wire messages are intentionally excluded from this namespace.
  """

  @type t :: Subscribe.t() | Unsubscribe.t() | Close.t()

  defmodule Subscribe do
    @moduledoc "Subscribes to one application-level track address."

    @enforce_keys [:track]
    defstruct [:track, options: []]

    @type t :: %__MODULE__{track: MOQX.TrackRef.t(), options: keyword()}
  end

  defmodule Unsubscribe do
    @moduledoc "Ends one subscription created through the public API."

    @enforce_keys [:subscription]
    defstruct [:subscription]

    @type t :: %__MODULE__{subscription: term()}
  end

  defmodule Close do
    @moduledoc "Requests graceful connection shutdown."

    defstruct [:reason]

    @type t :: %__MODULE__{reason: term()}
  end
end
