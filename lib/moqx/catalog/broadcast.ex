defmodule MOQX.Catalog.Broadcast do
  @moduledoc false

  def resolve(namespace, reference) when reference in [nil, ""], do: {:ok, namespace}
  def resolve(nil, _reference), do: {:error, :catalog_namespace_required}

  def resolve(namespace, reference) do
    base = namespace |> Enum.join("/") |> String.split("/") |> Enum.drop(-1)

    reference
    |> String.split("/")
    |> Enum.reduce_while({:ok, base}, fn
      ".", acc -> {:cont, acc}
      "..", {:ok, []} -> {:halt, {:error, :broadcast_outside_root}}
      "..", {:ok, segments} -> {:cont, {:ok, Enum.drop(segments, -1)}}
      part, {:ok, segments} -> {:cont, {:ok, segments ++ [part]}}
    end)
  end
end
