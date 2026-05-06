defmodule MOQX.Transport.Capabilities do
  @moduledoc """
  Normalized transport capability report for a negotiated connection.
  """

  @type availability :: boolean() | :unknown | :unsupported

  @type t :: %__MODULE__{
          alpn: binary() | :unknown | :unsupported,
          datagrams: availability(),
          max_datagram_size: non_neg_integer() | :unknown | :unsupported,
          stream_directions: [:bidirectional | :unidirectional],
          stream_priority: :supported | :unsupported | :unknown,
          transport_stats: :supported | :unsupported | :unknown
        }

  defstruct alpn: :unknown,
            datagrams: :unknown,
            max_datagram_size: :unknown,
            stream_directions: [:bidirectional, :unidirectional],
            stream_priority: :unknown,
            transport_stats: :unknown

  @doc """
  Builds normalized capabilities from `quicer` query results.
  """
  @spec from_quicer(
          {:ok, binary() | charlist()} | {:error, term()},
          {:ok, boolean()} | {:error, term()},
          {:ok, boolean()} | {:error, term()}
        ) :: t()
  def from_quicer(negotiated_alpn, datagram_send_enabled, datagram_receive_enabled) do
    %__MODULE__{
      alpn: normalize_alpn_result(negotiated_alpn),
      datagrams: normalize_datagrams(datagram_send_enabled, datagram_receive_enabled),
      max_datagram_size: :unknown,
      stream_directions: [:bidirectional, :unidirectional],
      stream_priority: :supported,
      transport_stats: :supported
    }
  end

  defp normalize_alpn_result({:ok, alpn}) when is_binary(alpn), do: alpn
  defp normalize_alpn_result({:ok, alpn}) when is_list(alpn), do: List.to_string(alpn)
  defp normalize_alpn_result({:error, _reason}), do: :unknown

  defp normalize_datagrams({:ok, true}, {:ok, true}), do: true
  defp normalize_datagrams({:ok, false}, _receive), do: false
  defp normalize_datagrams(_send, {:ok, false}), do: false
  defp normalize_datagrams(_send, _receive), do: :unknown
end
