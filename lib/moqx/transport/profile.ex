defmodule MOQX.Transport.Profile do
  @moduledoc """
  Transport profile fixtures for MOQT-family tests and benchmarks.

  A profile describes the ALPN, negotiated transport capabilities, and
  protocol-level stream expectations that a higher layer may enforce. Profiles
  are not protocol implementations, and `MOQX.Transport` does not enforce these
  stream rules.

  The built-in profiles intentionally include the draft version in the atom
  where the negotiated ALPN includes it.
  """

  alias MOQX.Transport.Capabilities

  @enforce_keys [:name, :alpn, :capabilities, :stream_expectations]
  defstruct [:name, :alpn, :capabilities, :stream_expectations]

  @type name :: :draft_14 | :draft_16 | :moq_lite_05 | :streams_only

  @type t :: %__MODULE__{
          name: name(),
          alpn: binary(),
          capabilities: Capabilities.t(),
          stream_expectations: map()
        }

  @doc """
  Returns canonical profile names.
  """
  @spec names() :: [name()]
  def names, do: [:draft_14, :draft_16, :moq_lite_05, :streams_only]

  @doc """
  Fetches a profile by canonical name or profile struct.
  """
  @spec fetch(name() | t()) :: {:ok, t()} | {:error, :unknown_profile}
  def fetch(%__MODULE__{} = profile), do: {:ok, profile}

  def fetch(name) when is_atom(name) do
    case name do
      :draft_14 -> {:ok, draft_14()}
      :draft_16 -> {:ok, draft_16()}
      :moq_lite_05 -> {:ok, moq_lite_05()}
      :streams_only -> {:ok, streams_only()}
      _unknown -> {:error, :unknown_profile}
    end
  end

  def fetch(_profile), do: {:error, :unknown_profile}

  @doc """
  Fetches a profile, raising on unknown profile names.
  """
  @spec fetch!(name() | t()) :: t()
  def fetch!(profile) do
    case fetch(profile) do
      {:ok, profile} -> profile
      {:error, :unknown_profile} -> raise ArgumentError, "unknown transport profile"
    end
  end

  @doc """
  Returns a profile's normalized transport capabilities.
  """
  @spec capabilities(name() | t()) ::
          {:ok, Capabilities.t()} | {:error, :unknown_profile}
  def capabilities(profile) do
    with {:ok, profile} <- fetch(profile) do
      {:ok, profile.capabilities}
    end
  end

  @doc """
  Returns a profile's normalized transport capabilities, raising on unknown profiles.
  """
  @spec capabilities!(name() | t()) :: Capabilities.t()
  def capabilities!(profile), do: fetch!(profile).capabilities

  @doc """
  Returns a profile's native QUIC ALPN token.
  """
  @spec alpn(name() | t()) :: {:ok, binary()} | {:error, :unknown_profile}
  def alpn(profile) do
    with {:ok, profile} <- fetch(profile) do
      {:ok, profile.alpn}
    end
  end

  defp draft_14 do
    %__MODULE__{
      name: :draft_14,
      alpn: "moq-00",
      capabilities: %Capabilities{
        alpn: "moq-00",
        datagrams: true,
        max_datagram_size: 1200,
        stream_directions: [:bidirectional, :unidirectional],
        stream_priority: :supported,
        transport_stats: :unsupported
      },
      stream_expectations: %{
        control_stream: %{direction: :bidirectional, initiator: :client, count: :one},
        data_streams: %{direction: :unidirectional, role: :object_data},
        datagrams: %{available: true, role: :object_data}
      }
    }
  end

  defp streams_only do
    %__MODULE__{
      name: :streams_only,
      alpn: "moqx-streams",
      capabilities: %Capabilities{
        alpn: "moqx-streams",
        datagrams: false,
        max_datagram_size: :unsupported,
        stream_directions: [:bidirectional, :unidirectional],
        stream_priority: :supported,
        transport_stats: :unsupported
      },
      stream_expectations: %{
        bidirectional_streams: %{
          direction: :bidirectional,
          count: :many,
          role: :application_defined
        },
        data_streams: %{direction: :unidirectional, role: :application_defined},
        datagrams: %{available: false, role: :none}
      }
    }
  end

  defp moq_lite_05 do
    %__MODULE__{
      name: :moq_lite_05,
      alpn: "moq-lite-05",
      capabilities: %Capabilities{
        alpn: "moq-lite-05",
        datagrams: false,
        max_datagram_size: :unsupported,
        stream_directions: [:bidirectional, :unidirectional],
        stream_priority: :supported,
        transport_stats: :unsupported
      },
      stream_expectations: %{
        setup_stream: %{direction: :unidirectional, initiator: :client, count: :one},
        application_streams: %{direction: :either, count: :many},
        datagrams: %{available: false, role: :optional_object_data}
      }
    }
  end

  defp draft_16 do
    %__MODULE__{
      name: :draft_16,
      alpn: "moqt-16",
      capabilities: %Capabilities{
        alpn: "moqt-16",
        datagrams: true,
        max_datagram_size: 1200,
        stream_directions: [:bidirectional, :unidirectional],
        stream_priority: :supported,
        transport_stats: :unsupported
      },
      stream_expectations: %{
        control_stream: %{direction: :bidirectional, initiator: :client, count: :one},
        data_streams: %{direction: :unidirectional, role: :object_data},
        datagrams: %{available: true, role: :object_data}
      }
    }
  end
end
