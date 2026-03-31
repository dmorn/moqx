defmodule MOQX.Test.Auth do
  @moduledoc """
  Helpers for relay-authenticated integration tests.
  """

  @fixture_path Path.expand("fixtures/auth/root.jwk", __DIR__)
  @secret "test-secret-that-is-long-enough-for-hmac-sha256"
  @kid "moqx-test-auth-key-1"

  def fixture_path, do: @fixture_path

  def fixture_jwk do
    %{
      "alg" => "HS256",
      "key_ops" => ["sign", "verify"],
      "kty" => "oct",
      "k" => Base.url_encode64(@secret, padding: false),
      "kid" => @kid
    }
  end

  def signer, do: JOSE.JWK.from(fixture_jwk())

  def token(opts) when is_list(opts) do
    now = System.system_time(:second)

    claims = %{
      "root" => Keyword.fetch!(opts, :root),
      "put" => Keyword.get(opts, :put, []),
      "get" => Keyword.get(opts, :get, []),
      "cluster" => Keyword.get(opts, :cluster, false),
      "iat" => Keyword.get(opts, :iat, now),
      "exp" => Keyword.get(opts, :exp, now + 3600)
    }

    {_jws, jwt} =
      signer()
      |> JOSE.JWT.sign(%{"alg" => "HS256", "kid" => @kid, "typ" => "JWT"}, claims)
      |> JOSE.JWS.compact()

    jwt
  end

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
