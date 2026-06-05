defmodule Probed.Config do
  @moduledoc false

  @default_path "/etc/moqx-bench/probed.json"

  defstruct [:node_id, :bind_host, :bind_port, :work_dir, :token, tools: %{}]

  def default_path, do: @default_path

  def load!(opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())

    opts
    |> config_path(env)
    |> File.read!()
    |> Jason.decode!()
    |> apply_env_overrides(env)
    |> from_map!()
  end

  def from_map!(map) when is_map(map) do
    {host, port} = parse_bind(required(map, :bind))

    %__MODULE__{
      node_id: required(map, :node_id),
      bind_host: host,
      bind_port: port,
      work_dir: required(map, :work_dir),
      token: token!(map),
      tools: normalize_tools(Map.get(map, :tools) || Map.get(map, "tools") || %{})
    }
  end

  defp config_path(opts, env) do
    Keyword.get(opts, :config_path) || Map.get(env, "PROBED_CONFIG") ||
      Keyword.get(opts, :default_path, @default_path)
  end

  defp apply_env_overrides(map, env) do
    map
    |> put_override(env, "PROBED_BIND", "bind")
    |> put_override(env, "PROBED_TOKEN", "token")
    |> put_override(env, "PROBED_WORK_DIR", "work_dir")
    |> put_override(env, "PROBED_NODE_ID", "node_id")
  end

  defp put_override(map, env, env_key, config_key) do
    case Map.get(env, env_key) do
      value when is_binary(value) and value != "" -> Map.put(map, config_key, value)
      _missing -> map
    end
  end

  defp required(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) ||
      raise ArgumentError, "missing required probed config #{key}"
  end

  defp token!(map) do
    Map.get(map, :token) || Map.get(map, "token") || token_from_file!(map) ||
      raise ArgumentError, "missing required probed config token"
  end

  defp token_from_file!(map) do
    case Map.get(map, :token_file) || Map.get(map, "token_file") do
      nil -> nil
      path -> path |> File.read!() |> String.trim()
    end
  end

  defp parse_bind(bind) when is_binary(bind) do
    case String.split(bind, ":", parts: 2) do
      [host, port] -> {host, String.to_integer(port)}
      _invalid -> raise ArgumentError, "invalid probed bind #{inspect(bind)}"
    end
  end

  defp normalize_tools(tools) when is_map(tools) do
    Map.new(tools, fn {name, tool} ->
      path = Map.get(tool, :path) || Map.get(tool, "path")

      unless Path.type(path) == :absolute do
        raise ArgumentError, "configured tool #{name} path must be absolute"
      end

      {to_string(name), %{"path" => path}}
    end)
  end
end
