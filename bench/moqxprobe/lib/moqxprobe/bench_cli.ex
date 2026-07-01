defmodule MOQXProbe.BenchCLI do
  @moduledoc """
  Shared CLI-parsing and argument-shaping helpers for the `bench/*.exs`
  scripts (closed-loop `stream_clients.exs` and open-loop `paced_stream.exs`).

  These are pure helpers over parsed `OptionParser` keyword lists. Integer
  validation uses `Mix.raise/1` so a bad flag prints a clean CLI error; the
  scripts are only ever run under `mix run`.
  """

  @doc """
  Drops the leading `--` separator that `mix run script.exs -- ...` leaves in
  front of the script's own arguments.
  """
  @spec drop_mix_separator([String.t()]) :: [String.t()]
  def drop_mix_separator(["--" | argv]), do: argv
  def drop_mix_separator(argv), do: argv

  @doc """
  Fetches `key` from `opts` (or `default`) and requires it to be a positive
  integer.
  """
  @spec positive_integer(keyword(), atom(), integer()) :: integer()
  def positive_integer(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      value
    else
      Mix.raise("--#{cli_key(key)} must be a positive integer")
    end
  end

  @doc """
  Fetches `key` from `opts` (or `default`) and requires it to be a non-negative
  integer.
  """
  @spec non_negative_integer(keyword(), atom(), integer()) :: integer()
  def non_negative_integer(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value >= 0 do
      value
    else
      Mix.raise("--#{cli_key(key)} must be a non-negative integer")
    end
  end

  @doc """
  Renders an option key as its `--kebab-case` flag name (without the `--`).
  """
  @spec cli_key(atom()) :: String.t()
  def cli_key(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  @doc """
  Wraps a bare IPv6 address in brackets so it can be used in a URL authority.
  """
  @spec url_host(String.t()) :: String.t()
  def url_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[#{host}]"
    else
      host
    end
  end

  @doc """
  Reconstructs the CLI argument list from parsed `opts` for the run manifest
  (ADR-0009 experiment-lifecycle layer). Boolean flags render as bare flags.
  """
  @spec manifest_args(keyword()) :: [String.t()]
  def manifest_args(opts) do
    Enum.flat_map(opts, fn {key, value} ->
      flag = "--#{cli_key(key)}"

      case value do
        true -> [flag]
        false -> []
        value -> [flag, to_string(value)]
      end
    end)
  end
end
