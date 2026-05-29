defmodule MOQXProbe.ReleaseCLI do
  @moduledoc false

  alias MOQXProbe.CLI

  @argv_env "MOQXPROBE_ARGV_B64"

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
