defmodule MOQX.Transport.Quicer.Options do
  @moduledoc """
  Pure normalization helpers for values passed from Elixir into `quicer`.

  `quicer` is an Erlang library, so its `string()` types are charlists. This
  module keeps that conversion explicit and away from protocol code.
  """

  @spec normalize_host(String.t() | :inet.ip_address()) :: charlist() | :inet.ip_address()
  def normalize_host(host) when is_binary(host), do: String.to_charlist(host)
  def normalize_host(host), do: host

  @spec normalize_text(String.t() | charlist() | term()) :: charlist() | term()
  def normalize_text(text) when is_binary(text), do: String.to_charlist(text)
  def normalize_text(text), do: text

  @quic_stream_open_flag_none 0
  @quic_stream_open_flag_unidirectional 1
  @quic_stream_start_flag_immediate 1
  @quicer_stream_event_mask_start_complete 1

  @spec normalize_opts(keyword() | map()) :: map()
  def normalize_opts(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> normalize_opts()
  end

  def normalize_opts(opts) when is_map(opts) do
    opts
    |> normalize_option(:alpn, &normalize_alpn/1)
    |> normalize_option(:cacertfile, &normalize_text/1)
    |> normalize_option(:certfile, &normalize_text/1)
    |> normalize_option(:keyfile, &normalize_text/1)
  end

  @spec normalize_stream_opts(keyword() | map()) :: map()
  def normalize_stream_opts(opts) do
    opts
    |> normalize_opts()
    |> normalize_direction()
    |> Map.put_new(:active, false)
    |> Map.put_new(:quic_event_mask, @quicer_stream_event_mask_start_complete)
    |> Map.put_new(:start_flag, @quic_stream_start_flag_immediate)
  end

  @spec normalize_accept_stream_opts(keyword() | map()) :: map()
  def normalize_accept_stream_opts(opts) do
    opts
    |> normalize_opts()
    |> Map.put_new(:active, false)
  end

  @spec normalize_alpn(binary() | charlist() | [binary() | charlist()] | nil) ::
          [charlist()] | nil
  def normalize_alpn(nil), do: nil
  def normalize_alpn(alpn) when is_binary(alpn), do: [String.to_charlist(alpn)]

  def normalize_alpn(alpn) when is_list(alpn) do
    if Enum.all?(alpn, &is_integer/1) do
      [alpn]
    else
      Enum.map(alpn, &normalize_text/1)
    end
  end

  defp normalize_direction(%{direction: direction} = opts) do
    opts
    |> Map.delete(:direction)
    |> Map.put(:open_flag, stream_open_flag(direction))
  end

  defp normalize_direction(opts), do: opts

  defp stream_open_flag(:bidirectional), do: @quic_stream_open_flag_none
  defp stream_open_flag(:unidirectional), do: @quic_stream_open_flag_unidirectional

  defp normalize_option(opts, key, normalizer) do
    if Map.has_key?(opts, key) do
      Map.update!(opts, key, normalizer)
    else
      opts
    end
  end
end
