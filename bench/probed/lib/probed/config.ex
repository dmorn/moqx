defmodule Probed.Config do
  @moduledoc false

  defstruct [:node_id, :bind_host, :bind_port, :work_dir, :token, tools: %{}]

  def from_map!(map) when is_map(map) do
    {host, port} = parse_bind(Map.fetch!(map, :bind) || Map.fetch!(map, "bind"))

    %__MODULE__{
      node_id: required(map, :node_id),
      bind_host: host,
      bind_port: port,
      work_dir: required(map, :work_dir),
      token: required(map, :token),
      tools: normalize_tools(Map.get(map, :tools) || Map.get(map, "tools") || %{})
    }
  end

  defp required(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) ||
      raise ArgumentError, "missing required probed config #{key}"
  end

  defp parse_bind(bind) when is_binary(bind) do
    case String.split(bind, ":", parts: 2) do
      [host, port] -> {host, String.to_integer(port)}
      _invalid -> raise ArgumentError, "invalid probed bind #{inspect(bind)}"
    end
  end

  defp normalize_tools(tools) when is_map(tools) do
    Map.new(tools, fn {name, tool} ->
      path = Map.get(tool, :path) || Map.fetch!(tool, "path")

      unless Path.type(path) == :absolute do
        raise ArgumentError, "configured tool #{name} path must be absolute"
      end

      {to_string(name), %{"path" => path}}
    end)
  end
end
