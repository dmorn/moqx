defmodule MOQX.Test.Auth do
  @moduledoc """
  URL normalization helpers for auth-related tests.
  """

  def connect_url(base_url, root, jwt)
      when is_binary(base_url) and is_binary(root) and is_binary(jwt) do
    uri = URI.parse(base_url)
    path = "/" <> String.trim(root, "/")
    query = URI.encode_query(%{"jwt" => jwt})

    uri
    |> Map.put(:path, path)
    |> Map.put(:query, query)
    |> URI.to_string()
  end

  def connect_url(base_url, root) when is_binary(base_url) and is_binary(root) do
    uri = URI.parse(base_url)
    path = "/" <> String.trim(root, "/")

    uri
    |> Map.put(:path, path)
    |> Map.put(:query, nil)
    |> URI.to_string()
  end
end
