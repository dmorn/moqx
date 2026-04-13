defmodule MOQX.RequestError do
  @moduledoc """
  Asynchronous request-level failure.

  `t:t/0` is used when an operation is rejected by API contract, session role,
  relay availability, or protocol-level request semantics.
  """

  @enforce_keys [:op, :message]
  defstruct [:op, :message, :code, :ref, :handle]

  @type op ::
          :connect
          | :publish
          | :subscribe
          | :fetch
          | :open_subgroup
          | :write_object
          | :close_subgroup
          | :flush_subgroup

  @type t :: %__MODULE__{
          op: op(),
          message: String.t(),
          code: atom() | non_neg_integer() | nil,
          ref: reference() | nil,
          handle: reference() | nil
        }
end

defmodule MOQX.TransportError do
  @moduledoc """
  Asynchronous transport/runtime failure.

  `t:t/0` is used for connection, stream, runtime, or task-level failures that
  occur after an operation has been accepted.
  """

  @enforce_keys [:op, :message]
  defstruct [:op, :message, :kind, :ref, :handle]

  @type op :: MOQX.RequestError.op()

  @type t :: %__MODULE__{
          op: op(),
          message: String.t(),
          kind: atom() | nil,
          ref: reference() | nil,
          handle: reference() | nil
        }
end

defmodule MOQX.ConnectOk do
  @moduledoc """
  Successful asynchronous connect result.
  """

  @enforce_keys [:ref, :session, :role, :version]
  defstruct [:ref, :session, :role, :version]

  @type t :: %__MODULE__{
          ref: reference(),
          session: reference(),
          role: MOQX.role(),
          version: MOQX.version()
        }
end

defmodule MOQX.PublishOk do
  @moduledoc """
  Successful asynchronous publish-namespace readiness result.
  """

  @enforce_keys [:ref, :broadcast, :namespace]
  defstruct [:ref, :broadcast, :namespace]

  @type t :: %__MODULE__{
          ref: reference(),
          broadcast: reference(),
          namespace: String.t()
        }
end

defmodule MOQX.SubscribeOk do
  @moduledoc """
  Successful asynchronous subscribe establishment event.
  """

  @enforce_keys [:handle, :namespace, :track_name]
  defstruct [:handle, :namespace, :track_name]

  @type t :: %__MODULE__{
          handle: reference(),
          namespace: String.t(),
          track_name: String.t()
        }
end

defmodule MOQX.TrackInit do
  @moduledoc """
  One-time subscription initialization payload.
  """

  @enforce_keys [:handle, :track_meta]
  defstruct [:handle, :init_data, :track_meta]

  @type t :: %__MODULE__{
          handle: reference(),
          init_data: binary() | nil,
          track_meta: map()
        }
end

defmodule MOQX.ObjectReceived do
  @moduledoc """
  Wrapper around one delivered `%MOQX.Object{}` with subscription correlation.
  """

  @enforce_keys [:handle, :object]
  defstruct [:handle, :object]

  @type t :: %__MODULE__{
          handle: reference(),
          object: MOQX.Object.t()
        }
end

defmodule MOQX.EndOfGroup do
  @moduledoc """
  End-of-group notification for a subscription.
  """

  @enforce_keys [:handle, :group_id, :subgroup_id]
  defstruct [:handle, :group_id, :subgroup_id]

  @type t :: %__MODULE__{
          handle: reference(),
          group_id: non_neg_integer(),
          subgroup_id: non_neg_integer()
        }
end

defmodule MOQX.PublishDone do
  @moduledoc """
  Terminal publish/subscription lifecycle event.
  """

  @enforce_keys [:handle, :status]
  defstruct [:handle, :status, :code, :message]

  @type status :: :ended | :unsubscribe_ack | :expired | :unknown

  @type t :: %__MODULE__{
          handle: reference(),
          status: status(),
          code: non_neg_integer() | nil,
          message: String.t() | nil
        }
end

defmodule MOQX.FlushDone do
  @moduledoc """
  Successful asynchronous subgroup flush completion.
  """

  @enforce_keys [:ref, :handle]
  defstruct [:ref, :handle]

  @type t :: %__MODULE__{
          ref: reference(),
          handle: reference()
        }
end

defmodule MOQX.FetchOk do
  @moduledoc """
  Fetch request accepted/start event.
  """

  @enforce_keys [:ref, :namespace, :track_name]
  defstruct [:ref, :namespace, :track_name]

  @type t :: %__MODULE__{
          ref: reference(),
          namespace: String.t(),
          track_name: String.t()
        }
end

defmodule MOQX.FetchObject do
  @moduledoc """
  One object received from an active fetch.
  """

  @enforce_keys [:ref, :group_id, :object_id, :payload]
  defstruct [:ref, :group_id, :object_id, :payload]

  @type t :: %__MODULE__{
          ref: reference(),
          group_id: non_neg_integer(),
          object_id: non_neg_integer(),
          payload: binary()
        }
end

defmodule MOQX.FetchDone do
  @moduledoc """
  Terminal fetch completion event.
  """

  @enforce_keys [:ref]
  defstruct [:ref]

  @type t :: %__MODULE__{ref: reference()}
end
