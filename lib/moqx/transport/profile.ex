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

  @type name :: :draft_14 | :moq_lite_04

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
  def names, do: [:draft_14, :moq_lite_04]

  @doc """
  Fetches a profile by canonical name or profile struct.
  """
  @spec fetch(name() | t()) :: {:ok, t()} | {:error, :unknown_profile}
  def fetch(%__MODULE__{} = profile), do: {:ok, profile}

  def fetch(name) when is_atom(name) do
    case name do
      :draft_14 -> {:ok, draft_14()}
      :moq_lite_04 -> {:ok, moq_lite_04()}
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

  defp moq_lite_04 do
    %__MODULE__{
      name: :moq_lite_04,
      alpn: "moq-lite-04",
      capabilities: %Capabilities{
        alpn: "moq-lite-04",
        datagrams: false,
        max_datagram_size: :unsupported,
        stream_directions: [:bidirectional, :unidirectional],
        stream_priority: :supported,
        transport_stats: :unsupported
      },
      stream_expectations: %{
        transaction_streams: %{
          direction: :bidirectional,
          count: :many,
          roles: [:announce, :subscribe, :fetch, :probe, :goaway]
        },
        group_streams: %{direction: :unidirectional, initiator: :publisher, role: :group_data},
        datagrams: %{available: false, role: :none}
      }
    }
  end
end
