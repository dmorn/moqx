defmodule Probed.Application do
  @moduledoc false

  use Application

  alias Probed.Config

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(),
      name: Probed.Supervisor,
      strategy: :one_for_one
    )
  end

  def children(opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    default_path = Keyword.get(opts, :default_path, Config.default_path())
    config_path = Map.get(env, "PROBED_CONFIG") || default_path

    if File.exists?(config_path) do
      config = Config.load!(env: env, default_path: default_path)

      [
        {Probed.Runner, name: Probed.Runner, config: config},
        {Bandit,
         plug: {Probed.Router, runner: Probed.Runner},
         ip: bind_ip!(config),
         port: config.bind_port,
         startup_log: false}
      ]
    else
      []
    end
  end

  defp bind_ip!(config) do
    config.bind_host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      {:error, reason} -> raise ArgumentError, "invalid probed bind host: #{inspect(reason)}"
    end
  end
end
