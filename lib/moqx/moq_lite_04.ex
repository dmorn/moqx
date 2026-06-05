defmodule MOQX.MOQLite04 do
  @moduledoc """
  Data model for MOQ Lite draft-04 messages.

  This module records protocol constants and message structs only. Payload
  codecs use the generic `MOQX.Codec` contracts; stream framing and session
  behavior are intentionally separate concerns.
  """

  @typedoc "MOQ Lite draft-04 stream type."
  @type stream_type :: :group | :announce | :subscribe | :fetch | :probe | :goaway

  @typedoc "MOQ Lite draft-04 message struct."
  @type message ::
          AnnounceInterest.t()
          | Announce.t()
          | Subscribe.t()
          | SubscribeUpdate.t()
          | SubscribeOk.t()
          | SubscribeDrop.t()
          | Fetch.t()
          | Probe.t()
          | Goaway.t()
          | Group.t()
          | Frame.t()

  @stream_type_to_id %{
    group: 0x0,
    announce: 0x1,
    subscribe: 0x2,
    fetch: 0x3,
    probe: 0x4,
    goaway: 0x5
  }

  @id_to_stream_type Map.new(@stream_type_to_id, fn {type, id} -> {id, type} end)

  @doc """
  Returns the draft-04 numeric stream type ID for a known stream type.
  """
  @spec stream_type_id(stream_type()) :: {:ok, non_neg_integer()} | {:error, :unknown_stream_type}
  def stream_type_id(type) do
    case Map.fetch(@stream_type_to_id, type) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :unknown_stream_type}
    end
  end

  @doc """
  Returns the draft-04 stream type for a numeric stream type ID.
  """
  @spec stream_type(non_neg_integer()) :: {:ok, stream_type()} | {:error, :unknown_stream_type}
  def stream_type(id) when is_integer(id) and id >= 0 do
    case Map.fetch(@id_to_stream_type, id) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unknown_stream_type}
    end
  end

  @typedoc "ANNOUNCE status value after decoding from the wire."
  @type announce_status :: :ended | :active

  @typedoc "Relative group transmission preference."
  @type group_order :: :ascending | :descending

  defmodule AnnounceInterest do
    @moduledoc """
    Subscriber request for broadcast announcements matching a path prefix.
    """

    @enforce_keys [:broadcast_path_prefix]
    defstruct [:broadcast_path_prefix, exclude_hop: 0]

    @type t :: %__MODULE__{
            broadcast_path_prefix: String.t(),
            exclude_hop: non_neg_integer()
          }
  end

  defmodule Announce do
    @moduledoc """
    Publisher announcement that a broadcast path became active or ended.
    """

    @enforce_keys [:status, :broadcast_path_suffix]
    defstruct [:status, :broadcast_path_suffix, hop_ids: []]

    @type t :: %__MODULE__{
            status: MOQX.MOQLite04.announce_status(),
            broadcast_path_suffix: String.t(),
            hop_ids: [non_neg_integer()]
          }
  end

  defmodule Subscribe do
    @moduledoc """
    Subscriber request to start receiving one track.
    """

    @enforce_keys [
      :subscribe_id,
      :broadcast_path,
      :track_name,
      :subscriber_priority,
      :subscriber_ordered,
      :subscriber_max_latency,
      :start_group,
      :end_group
    ]
    defstruct [
      :subscribe_id,
      :broadcast_path,
      :track_name,
      :subscriber_priority,
      :subscriber_ordered,
      :subscriber_max_latency,
      :start_group,
      :end_group
    ]

    @type t :: %__MODULE__{
            subscribe_id: non_neg_integer(),
            broadcast_path: String.t(),
            track_name: String.t(),
            subscriber_priority: 0..255,
            subscriber_ordered: MOQX.MOQLite04.group_order(),
            subscriber_max_latency: non_neg_integer(),
            start_group: non_neg_integer(),
            end_group: non_neg_integer()
          }
  end

  defmodule SubscribeUpdate do
    @moduledoc """
    Subscriber update for an existing Subscribe stream.
    """

    @enforce_keys [
      :subscriber_priority,
      :subscriber_ordered,
      :subscriber_max_latency,
      :start_group,
      :end_group
    ]
    defstruct [
      :subscriber_priority,
      :subscriber_ordered,
      :subscriber_max_latency,
      :start_group,
      :end_group
    ]

    @type t :: %__MODULE__{
            subscriber_priority: 0..255,
            subscriber_ordered: MOQX.MOQLite04.group_order(),
            subscriber_max_latency: non_neg_integer(),
            start_group: non_neg_integer(),
            end_group: non_neg_integer()
          }
  end

  defmodule SubscribeOk do
    @moduledoc """
    Publisher response or update for a Subscribe stream.
    """

    @enforce_keys [
      :publisher_priority,
      :publisher_ordered,
      :publisher_max_latency,
      :start_group,
      :end_group
    ]
    defstruct [
      :publisher_priority,
      :publisher_ordered,
      :publisher_max_latency,
      :start_group,
      :end_group
    ]

    @type t :: %__MODULE__{
            publisher_priority: 0..255,
            publisher_ordered: MOQX.MOQLite04.group_order(),
            publisher_max_latency: non_neg_integer(),
            start_group: non_neg_integer(),
            end_group: non_neg_integer()
          }
  end

  defmodule SubscribeDrop do
    @moduledoc """
    Publisher response marking a group range unavailable on a Subscribe stream.
    """

    @enforce_keys [:start_group, :end_group, :error_code]
    defstruct [:start_group, :end_group, :error_code]

    @type t :: %__MODULE__{
            start_group: non_neg_integer(),
            end_group: non_neg_integer(),
            error_code: non_neg_integer()
          }
  end

  defmodule Fetch do
    @moduledoc """
    Subscriber request for a single group from a track.
    """

    @enforce_keys [:broadcast_path, :track_name, :subscriber_priority, :group_sequence]
    defstruct [:broadcast_path, :track_name, :subscriber_priority, :group_sequence]

    @type t :: %__MODULE__{
            broadcast_path: String.t(),
            track_name: String.t(),
            subscriber_priority: 0..255,
            group_sequence: non_neg_integer()
          }
  end

  defmodule Probe do
    @moduledoc """
    Bidirectional probe message for connection bitrate and RTT estimates.
    """

    @enforce_keys [:bitrate, :rtt]
    defstruct [:bitrate, :rtt]

    @type t :: %__MODULE__{
            bitrate: non_neg_integer(),
            rtt: non_neg_integer()
          }
  end

  defmodule Goaway do
    @moduledoc """
    Graceful session shutdown message with an optional redirect URI.
    """

    @enforce_keys [:new_session_uri]
    defstruct [:new_session_uri]

    @type t :: %__MODULE__{
            new_session_uri: String.t()
          }
  end

  defmodule Group do
    @moduledoc """
    Header message for one unidirectional group stream.
    """

    @enforce_keys [:subscribe_id, :group_sequence]
    defstruct [:subscribe_id, :group_sequence]

    @type t :: %__MODULE__{
            subscribe_id: non_neg_integer(),
            group_sequence: non_neg_integer()
          }
  end

  defmodule Frame do
    @moduledoc """
    Opaque application payload within a group or fetch response.
    """

    @enforce_keys [:payload]
    defstruct [:payload]

    @type t :: %__MODULE__{
            payload: binary()
          }
  end
end
