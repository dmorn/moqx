defmodule MOQX.Protocol.MOQLite05.Messages do
  @moduledoc "Semantic wire messages for MoQ Lite draft-05."

  defmodule Setup do
    @moduledoc "Capabilities and client routing intent sent on the Setup Stream."

    defstruct probe: :none, path: nil, role: :both

    @type probe :: :none | :report | :increase
    @type role :: :both | :publisher | :subscriber

    @type t :: %__MODULE__{
            probe: probe(),
            path: String.t() | nil,
            role: role()
          }
  end

  defmodule TrackInfo do
    @moduledoc "Immutable publisher properties returned on a Track Stream."

    @enforce_keys [
      :publisher_priority,
      :publisher_ordered,
      :publisher_max_latency,
      :timescale
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            publisher_priority: 0..255,
            publisher_ordered: boolean(),
            publisher_max_latency: non_neg_integer(),
            timescale: pos_integer()
          }
  end

  defmodule Track do
    @moduledoc "Request for one track's immutable publisher properties."

    @enforce_keys [:broadcast_path, :track_name]
    defstruct @enforce_keys

    @type t :: %__MODULE__{broadcast_path: String.t(), track_name: String.t()}
  end

  defmodule Subscribe do
    @moduledoc "Subscriber request that opens a Subscribe Stream."

    @enforce_keys [:subscribe_id, :broadcast_path, :track_name, :subscriber_priority]
    defstruct @enforce_keys ++
                [
                  subscriber_ordered: false,
                  subscriber_max_latency: 0,
                  group_start: nil,
                  group_end: nil
                ]

    @type t :: %__MODULE__{
            subscribe_id: non_neg_integer(),
            broadcast_path: String.t(),
            track_name: String.t(),
            subscriber_priority: 0..255,
            subscriber_ordered: boolean(),
            subscriber_max_latency: non_neg_integer(),
            group_start: non_neg_integer() | nil,
            group_end: non_neg_integer() | nil
          }
  end

  defmodule SubscribeUpdate do
    @moduledoc "Mutable subscriber delivery preferences sent on a Subscribe Stream."

    @enforce_keys [:subscriber_priority]
    defstruct @enforce_keys ++
                [
                  subscriber_ordered: false,
                  subscriber_max_latency: 0,
                  group_start: nil,
                  group_end: nil
                ]

    @type t :: %__MODULE__{
            subscriber_priority: 0..255,
            subscriber_ordered: boolean(),
            subscriber_max_latency: non_neg_integer(),
            group_start: non_neg_integer() | nil,
            group_end: non_neg_integer() | nil
          }
  end

  defmodule SubscribeOk do
    @moduledoc "Publisher acceptance and resolved first group for a subscription."
    @enforce_keys [:group]
    defstruct @enforce_keys
    @type t :: %__MODULE__{group: non_neg_integer()}
  end

  defmodule SubscribeEnd do
    @moduledoc "Publisher declaration of the last group that may be delivered."
    @enforce_keys [:group]
    defstruct @enforce_keys
    @type t :: %__MODULE__{group: non_neg_integer()}
  end

  defmodule SubscribeDrop do
    @moduledoc "Publisher declaration that an absolute group range is unavailable."
    @enforce_keys [:group_start, :group_end, :error_code]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            group_start: non_neg_integer(),
            group_end: non_neg_integer(),
            error_code: non_neg_integer()
          }
  end

  defmodule Frame do
    @moduledoc "One length-delimited payload with a signed track-timescale timestamp delta."
    @enforce_keys [:timestamp_delta, :payload]
    defstruct @enforce_keys
    @type t :: %__MODULE__{timestamp_delta: integer(), payload: binary()}
  end

  defmodule Group do
    @moduledoc "Header that identifies one published group and its subscription."
    @enforce_keys [:subscribe_id, :group_sequence]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            subscribe_id: non_neg_integer(),
            group_sequence: non_neg_integer()
          }
  end

  defmodule AnnounceRequest do
    @moduledoc "Subscriber interest in broadcasts under one path prefix."
    @enforce_keys [:broadcast_path_prefix]
    defstruct @enforce_keys ++ [exclude_hop: 0]

    @type t :: %__MODULE__{
            broadcast_path_prefix: String.t(),
            exclude_hop: non_neg_integer()
          }
  end

  defmodule AnnounceOk do
    @moduledoc "Publisher identity and initial announcement count."
    @enforce_keys [:hop_id, :active_count]
    defstruct @enforce_keys
    @type t :: %__MODULE__{hop_id: non_neg_integer(), active_count: non_neg_integer()}
  end

  defmodule AnnounceBroadcast do
    @moduledoc "One broadcast availability update on an Announce Stream."
    @enforce_keys [:status, :path_suffix, :hop_ids]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            status: :ended | :active,
            path_suffix: String.t(),
            hop_ids: [non_neg_integer()]
          }
  end
end
