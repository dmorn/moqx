defmodule MOQX.MOQLite04 do
  @moduledoc """
  MOQ Lite draft-04 protocol variant facade and message data model.

  Payload codecs use the generic `MOQX.Codec` contracts. Stream framing,
  session behavior, and client connection setup are variant-specific concerns
  layered under this module.
  """

  alias MOQX.MOQLite04.Client

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

  @typedoc "SUBSCRIBE response discriminator value."
  @type subscribe_response_type :: :ok | :drop

  @subscribe_response_type_to_id %{
    ok: 0x0,
    drop: 0x1
  }

  @id_to_subscribe_response_type Map.new(@subscribe_response_type_to_id, fn {type, id} ->
                                   {id, type}
                                 end)

  @doc """
  Connects to a native QUIC MOQ Lite draft-04 endpoint.
  """
  @spec connect(String.t() | URI.t(), keyword()) :: {:ok, Client.t()} | {:error, term()}
  def connect(uri, opts \\ []), do: Client.connect(uri, opts)

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

  @doc """
  Returns the draft-04 numeric SUBSCRIBE response discriminator for a known type.
  """
  @spec subscribe_response_type_id(subscribe_response_type()) ::
          {:ok, non_neg_integer()} | {:error, :unknown_subscribe_response_type}
  def subscribe_response_type_id(type) do
    case Map.fetch(@subscribe_response_type_to_id, type) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :unknown_subscribe_response_type}
    end
  end

  @doc """
  Returns the draft-04 SUBSCRIBE response type for a numeric discriminator.
  """
  @spec subscribe_response_type(non_neg_integer()) ::
          {:ok, subscribe_response_type()} | {:error, :unknown_subscribe_response_type}
  def subscribe_response_type(id) when is_integer(id) and id >= 0 do
    case Map.fetch(@id_to_subscribe_response_type, id) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unknown_subscribe_response_type}
    end
  end

  @typedoc "ANNOUNCE status value after decoding from the wire."
  @type announce_status :: :ended | :active

  @doc false
  @spec announce_status_id(announce_status()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_announce_status}
  def announce_status_id(:ended), do: {:ok, 0}
  def announce_status_id(:active), do: {:ok, 1}
  def announce_status_id(_status), do: {:error, :invalid_announce_status}

  @doc false
  @spec announce_status(non_neg_integer()) ::
          {:ok, announce_status()} | {:error, :invalid_announce_status}
  def announce_status(0), do: {:ok, :ended}
  def announce_status(1), do: {:ok, :active}
  def announce_status(_status), do: {:error, :invalid_announce_status}

  @typedoc "Relative group transmission preference."
  @type group_order :: :ascending | :descending

  @doc false
  @spec group_order_id(group_order()) :: {:ok, non_neg_integer()} | {:error, :invalid_group_order}
  def group_order_id(:descending), do: {:ok, 0}
  def group_order_id(:ascending), do: {:ok, 1}
  def group_order_id(_order), do: {:error, :invalid_group_order}

  @doc false
  @spec group_order(non_neg_integer()) :: {:ok, group_order()} | {:error, :invalid_group_order}
  def group_order(0), do: {:ok, :descending}
  def group_order(1), do: {:ok, :ascending}
  def group_order(_order), do: {:error, :invalid_group_order}

  @doc false
  @spec complete_payload(binary()) :: :ok | {:error, :trailing_bytes}
  def complete_payload(<<>>), do: :ok
  def complete_payload(_rest), do: {:error, :trailing_bytes}

  @doc false
  @spec encode_uint8(0..255) :: binary()
  def encode_uint8(value) when is_integer(value) and value >= 0 and value <= 255 do
    <<value>>
  end

  @doc false
  @spec decode_uint8(binary()) :: {:ok, 0..255, binary()} | {:error, :incomplete}
  def decode_uint8(<<value, rest::binary>>), do: {:ok, value, rest}
  def decode_uint8(_data), do: {:error, :incomplete}

  defmodule AnnounceInterest do
    @behaviour MOQX.Codec.Decoder

    @moduledoc """
    Subscriber request for broadcast announcements matching a path prefix.
    """

    @enforce_keys [:broadcast_path_prefix]
    defstruct [:broadcast_path_prefix, exclude_hop: 0]

    @type t :: %__MODULE__{
            broadcast_path_prefix: String.t(),
            exclude_hop: non_neg_integer()
          }

    @impl true
    def decode(payload, _context) do
      with {:ok, broadcast_path_prefix, rest} <- MOQX.Codec.decode_string(payload),
           {:ok, exclude_hop, rest} <- MOQX.Codec.decode_varint(rest),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok,
         %__MODULE__{
           broadcast_path_prefix: broadcast_path_prefix,
           exclude_hop: exclude_hop
         }}
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        [
          MOQX.Codec.encode_string(message.broadcast_path_prefix),
          MOQX.Codec.encode_varint(message.exclude_hop)
        ]
        |> IO.iodata_to_binary()
      end
    end
  end

  defmodule Announce do
    @behaviour MOQX.Codec.Decoder

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

    @impl true
    def decode(payload, _context) do
      with {:ok, status_id, rest} <- MOQX.Codec.decode_varint(payload),
           {:ok, status} <- MOQX.MOQLite04.announce_status(status_id),
           {:ok, broadcast_path_suffix, rest} <- MOQX.Codec.decode_string(rest),
           {:ok, hop_count, rest} <- MOQX.Codec.decode_varint(rest),
           {:ok, hop_ids, rest} <- decode_hop_ids(rest, hop_count, []),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok,
         %__MODULE__{
           status: status,
           broadcast_path_suffix: broadcast_path_suffix,
           hop_ids: hop_ids
         }}
      end
    end

    defp decode_hop_ids(rest, 0, hop_ids), do: {:ok, Enum.reverse(hop_ids), rest}

    defp decode_hop_ids(payload, count, hop_ids) do
      with {:ok, hop_id, rest} <- MOQX.Codec.decode_varint(payload) do
        decode_hop_ids(rest, count - 1, [hop_id | hop_ids])
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        hop_ids = Enum.map(message.hop_ids, &MOQX.Codec.encode_varint/1)
        {:ok, status_id} = MOQX.MOQLite04.announce_status_id(message.status)

        [
          MOQX.Codec.encode_varint(status_id),
          MOQX.Codec.encode_string(message.broadcast_path_suffix),
          MOQX.Codec.encode_varint(length(message.hop_ids)),
          hop_ids
        ]
        |> IO.iodata_to_binary()
      end
    end
  end

  defmodule Subscribe do
    @behaviour MOQX.Codec.Decoder

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

    @impl true
    def decode(payload, _context) do
      with {:ok, subscribe_id, rest} <- MOQX.Codec.decode_varint(payload),
           {:ok, broadcast_path, rest} <- MOQX.Codec.decode_string(rest),
           {:ok, track_name, rest} <- MOQX.Codec.decode_string(rest),
           {:ok, subscriber_priority, rest} <- MOQX.MOQLite04.decode_uint8(rest),
           {:ok, ordered_id, rest} <- MOQX.MOQLite04.decode_uint8(rest),
           {:ok, subscriber_ordered} <- MOQX.MOQLite04.group_order(ordered_id),
           {:ok, subscriber_max_latency, rest} <- MOQX.Codec.decode_varint(rest),
           {:ok, start_group, rest} <- MOQX.Codec.decode_varint(rest),
           {:ok, end_group, rest} <- MOQX.Codec.decode_varint(rest),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok,
         %__MODULE__{
           subscribe_id: subscribe_id,
           broadcast_path: broadcast_path,
           track_name: track_name,
           subscriber_priority: subscriber_priority,
           subscriber_ordered: subscriber_ordered,
           subscriber_max_latency: subscriber_max_latency,
           start_group: start_group,
           end_group: end_group
         }}
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        {:ok, ordered_id} = MOQX.MOQLite04.group_order_id(message.subscriber_ordered)

        [
          MOQX.Codec.encode_varint(message.subscribe_id),
          MOQX.Codec.encode_string(message.broadcast_path),
          MOQX.Codec.encode_string(message.track_name),
          MOQX.MOQLite04.encode_uint8(message.subscriber_priority),
          MOQX.MOQLite04.encode_uint8(ordered_id),
          MOQX.Codec.encode_varint(message.subscriber_max_latency),
          MOQX.Codec.encode_varint(message.start_group),
          MOQX.Codec.encode_varint(message.end_group)
        ]
        |> IO.iodata_to_binary()
      end
    end
  end

  defmodule SubscribeUpdate do
    @behaviour MOQX.Codec.Decoder

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

    @impl true
    def decode(payload, _context) do
      with {:ok, subscriber_priority, rest} <- MOQX.MOQLite04.decode_uint8(payload),
           {:ok, ordered_id, rest} <- MOQX.MOQLite04.decode_uint8(rest),
           {:ok, subscriber_ordered} <- MOQX.MOQLite04.group_order(ordered_id),
           {:ok, subscriber_max_latency, rest} <- MOQX.Codec.decode_varint(rest),
           {:ok, start_group, rest} <- MOQX.Codec.decode_varint(rest),
           {:ok, end_group, rest} <- MOQX.Codec.decode_varint(rest),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok,
         %__MODULE__{
           subscriber_priority: subscriber_priority,
           subscriber_ordered: subscriber_ordered,
           subscriber_max_latency: subscriber_max_latency,
           start_group: start_group,
           end_group: end_group
         }}
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        {:ok, ordered_id} = MOQX.MOQLite04.group_order_id(message.subscriber_ordered)

        [
          MOQX.MOQLite04.encode_uint8(message.subscriber_priority),
          MOQX.MOQLite04.encode_uint8(ordered_id),
          MOQX.Codec.encode_varint(message.subscriber_max_latency),
          MOQX.Codec.encode_varint(message.start_group),
          MOQX.Codec.encode_varint(message.end_group)
        ]
        |> IO.iodata_to_binary()
      end
    end
  end

  defmodule SubscribeOk do
    @behaviour MOQX.Codec.Decoder

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

    @impl true
    def decode(payload, _context) do
      with {:ok, publisher_priority, rest} <- MOQX.MOQLite04.decode_uint8(payload),
           {:ok, ordered_id, rest} <- MOQX.MOQLite04.decode_uint8(rest),
           {:ok, publisher_ordered} <- MOQX.MOQLite04.group_order(ordered_id),
           {:ok, publisher_max_latency, rest} <- MOQX.Codec.decode_varint(rest),
           {:ok, start_group, rest} <- MOQX.Codec.decode_varint(rest),
           {:ok, end_group, rest} <- MOQX.Codec.decode_varint(rest),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok,
         %__MODULE__{
           publisher_priority: publisher_priority,
           publisher_ordered: publisher_ordered,
           publisher_max_latency: publisher_max_latency,
           start_group: start_group,
           end_group: end_group
         }}
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        {:ok, ordered_id} = MOQX.MOQLite04.group_order_id(message.publisher_ordered)

        [
          MOQX.MOQLite04.encode_uint8(message.publisher_priority),
          MOQX.MOQLite04.encode_uint8(ordered_id),
          MOQX.Codec.encode_varint(message.publisher_max_latency),
          MOQX.Codec.encode_varint(message.start_group),
          MOQX.Codec.encode_varint(message.end_group)
        ]
        |> IO.iodata_to_binary()
      end
    end
  end

  defmodule SubscribeDrop do
    @behaviour MOQX.Codec.Decoder

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

    @impl true
    def decode(payload, _context) do
      with {:ok, start_group, rest} <- MOQX.Codec.decode_varint(payload),
           {:ok, end_group, rest} <- MOQX.Codec.decode_varint(rest),
           {:ok, error_code, rest} <- MOQX.Codec.decode_varint(rest),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok,
         %__MODULE__{
           start_group: start_group,
           end_group: end_group,
           error_code: error_code
         }}
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        [
          MOQX.Codec.encode_varint(message.start_group),
          MOQX.Codec.encode_varint(message.end_group),
          MOQX.Codec.encode_varint(message.error_code)
        ]
        |> IO.iodata_to_binary()
      end
    end
  end

  defmodule Fetch do
    @behaviour MOQX.Codec.Decoder

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

    @impl true
    def decode(payload, _context) do
      with {:ok, broadcast_path, rest} <- MOQX.Codec.decode_string(payload),
           {:ok, track_name, rest} <- MOQX.Codec.decode_string(rest),
           {:ok, subscriber_priority, rest} <- MOQX.MOQLite04.decode_uint8(rest),
           {:ok, group_sequence, rest} <- MOQX.Codec.decode_varint(rest),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok,
         %__MODULE__{
           broadcast_path: broadcast_path,
           track_name: track_name,
           subscriber_priority: subscriber_priority,
           group_sequence: group_sequence
         }}
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        [
          MOQX.Codec.encode_string(message.broadcast_path),
          MOQX.Codec.encode_string(message.track_name),
          MOQX.MOQLite04.encode_uint8(message.subscriber_priority),
          MOQX.Codec.encode_varint(message.group_sequence)
        ]
        |> IO.iodata_to_binary()
      end
    end
  end

  defmodule Probe do
    @behaviour MOQX.Codec.Decoder

    @moduledoc """
    Bidirectional probe message for connection bitrate and RTT estimates.
    """

    @enforce_keys [:bitrate, :rtt]
    defstruct [:bitrate, :rtt]

    @type t :: %__MODULE__{
            bitrate: non_neg_integer(),
            rtt: non_neg_integer()
          }

    @impl true
    def decode(payload, _context) do
      with {:ok, bitrate, rest} <- MOQX.Codec.decode_varint(payload),
           {:ok, rtt, rest} <- MOQX.Codec.decode_varint(rest),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok, %__MODULE__{bitrate: bitrate, rtt: rtt}}
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        [
          MOQX.Codec.encode_varint(message.bitrate),
          MOQX.Codec.encode_varint(message.rtt)
        ]
        |> IO.iodata_to_binary()
      end
    end
  end

  defmodule Goaway do
    @behaviour MOQX.Codec.Decoder

    @moduledoc """
    Graceful session shutdown message with an optional redirect URI.
    """

    @enforce_keys [:new_session_uri]
    defstruct [:new_session_uri]

    @type t :: %__MODULE__{
            new_session_uri: String.t()
          }

    @impl true
    def decode(payload, _context) do
      with {:ok, new_session_uri, rest} <- MOQX.Codec.decode_string(payload),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok, %__MODULE__{new_session_uri: new_session_uri}}
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        MOQX.Codec.encode_string(message.new_session_uri)
      end
    end
  end

  defmodule Group do
    @behaviour MOQX.Codec.Decoder

    @moduledoc """
    Header message for one unidirectional group stream.
    """

    @enforce_keys [:subscribe_id, :group_sequence]
    defstruct [:subscribe_id, :group_sequence]

    @type t :: %__MODULE__{
            subscribe_id: non_neg_integer(),
            group_sequence: non_neg_integer()
          }

    @impl true
    def decode(payload, _context) do
      with {:ok, subscribe_id, rest} <- MOQX.Codec.decode_varint(payload),
           {:ok, group_sequence, rest} <- MOQX.Codec.decode_varint(rest),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok, %__MODULE__{subscribe_id: subscribe_id, group_sequence: group_sequence}}
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        [
          MOQX.Codec.encode_varint(message.subscribe_id),
          MOQX.Codec.encode_varint(message.group_sequence)
        ]
        |> IO.iodata_to_binary()
      end
    end
  end

  defmodule Frame do
    @behaviour MOQX.Codec.Decoder

    @moduledoc """
    Opaque application payload within a group or fetch response.
    """

    @enforce_keys [:payload]
    defstruct [:payload]

    @type t :: %__MODULE__{
            payload: binary()
          }

    @impl true
    def decode(payload, _context) do
      with {:ok, frame_payload, rest} <- MOQX.Codec.decode_bytes(payload),
           :ok <- MOQX.MOQLite04.complete_payload(rest) do
        {:ok, %__MODULE__{payload: frame_payload}}
      end
    end

    defimpl MOQX.Codec.Encoder do
      def encode(message) do
        MOQX.Codec.encode_bytes(message.payload)
      end
    end
  end
end
