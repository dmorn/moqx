defmodule MOQX.TransportBench.ReleaseCLI do
  @moduledoc false

  alias MOQX.TransportBench.CLI

  @argv_env "MOQX_TRANSPORT_BENCH_ARGV_B64"

  def main_from_env do
    @argv_env
    |> System.get_env("")
    |> decode_argv()
    |> CLI.main()
  end

  def decode_argv(encoded) when is_binary(encoded) do
    encoded
    |> String.split("\n", trim: true)
    |> Enum.map(&Base.decode64!/1)
  end
end
