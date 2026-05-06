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

  @spec normalize_opts(keyword() | map()) :: map()
  def normalize_opts(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> normalize_opts()
  end

  def normalize_opts(opts) when is_map(opts) do
    if Map.has_key?(opts, :alpn) do
      Map.update!(opts, :alpn, &normalize_alpn/1)
    else
      opts
    end
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
end
