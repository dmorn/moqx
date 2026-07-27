defmodule MOQX.SubscriptionParameter do
  @moduledoc "Protocol-neutral parameters attached to an inbound subscription request."

  @type t ::
          Authorization.t()
          | DeliveryTimeout.t()
          | Expires.t()
          | LargestObject.t()
          | GroupOrder.t()
          | Extension.t()

  defmodule Authorization do
    @moduledoc "Authorization material supplied with an inbound subscription."
    @enforce_keys [:value]
    defstruct [:value]
    @type t :: %__MODULE__{value: binary()}
  end

  defmodule DeliveryTimeout do
    @moduledoc "Requested object delivery timeout in milliseconds."
    @enforce_keys [:milliseconds]
    defstruct [:milliseconds]
    @type t :: %__MODULE__{milliseconds: non_neg_integer()}
  end

  defmodule Expires do
    @moduledoc "Relative subscription expiry in milliseconds."
    @enforce_keys [:milliseconds]
    defstruct [:milliseconds]
    @type t :: %__MODULE__{milliseconds: non_neg_integer()}
  end

  defmodule LargestObject do
    @moduledoc "Largest object location reported when a subscription is accepted."
    @enforce_keys [:location]
    defstruct [:location]
    @type t :: %__MODULE__{location: MOQX.SubscriptionFilter.location()}
  end

  defmodule GroupOrder do
    @moduledoc "Publisher group order selected for a subscription."
    @enforce_keys [:value]
    defstruct [:value]
    @type t :: %__MODULE__{value: :ascending | :descending}
  end

  defmodule Extension do
    @moduledoc "Unrecognized protocol-specific subscription parameter retained losslessly."
    @enforce_keys [:protocol, :identifier, :value]
    defstruct [:protocol, :identifier, :value]

    @type t :: %__MODULE__{
            protocol: atom(),
            identifier: non_neg_integer(),
            value: non_neg_integer() | binary()
          }
  end
end

defimpl Inspect, for: MOQX.SubscriptionParameter.Authorization do
  def inspect(_authorization, _options), do: "#MOQX.SubscriptionParameter.Authorization<REDACTED>"
end
