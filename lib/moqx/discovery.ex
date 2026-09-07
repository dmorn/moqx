defmodule MOQX.Discovery do
  @moduledoc "Connection-scoped handle for a live Lite broadcast-prefix discovery."
  @enforce_keys [:scope, :id, :prefix]
  defstruct [:scope, :id, :prefix]
  @opaque t :: %__MODULE__{scope: reference(), id: non_neg_integer(), prefix: binary()}
end

defmodule MOQX.Event.DiscoveryReady do
  @moduledoc "All initial matching broadcasts have been reported; live discovery continues."
  @enforce_keys [:discovery]
  defstruct [:discovery]
  @type t :: %__MODULE__{discovery: MOQX.Discovery.t()}
end

defmodule MOQX.Event.BroadcastAvailable do
  @moduledoc "A broadcast appeared in one discovery. Catalog subscription is a separate operation."
  @enforce_keys [:discovery, :path]
  defstruct [:discovery, :path]
  @type t :: %__MODULE__{discovery: MOQX.Discovery.t(), path: binary()}
end

defmodule MOQX.Event.BroadcastWithdrawn do
  @moduledoc "A broadcast is no longer available in one discovery."
  @enforce_keys [:discovery, :path, :reason]
  defstruct [:discovery, :path, :reason]
  @type t :: %__MODULE__{discovery: MOQX.Discovery.t(), path: binary(), reason: atom()}
end

defmodule MOQX.Event.DiscoveryDone do
  @moduledoc "A discovery ended after withdrawing every broadcast it previously reported."
  @enforce_keys [:discovery, :reason]
  defstruct [:discovery, :reason]
  @type t :: %__MODULE__{discovery: MOQX.Discovery.t(), reason: atom()}
end
