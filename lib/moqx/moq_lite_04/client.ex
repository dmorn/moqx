defmodule MOQX.MOQLite04.Client do
  @moduledoc """
  URI-first MOQ Lite draft-04 client connection value.

  This module establishes the transport connection and starts the pure
  `MOQX.MOQLite04.Session`. Protocol operations and event running are layered on
  top in later slices.
  """

  alias MOQX.MOQLite04.Error
  alias MOQX.MOQLite04.Session
  alias MOQX.Transport
  alias MOQX.Transport.{Capabilities, Connection, Context}

  @alpn "moq-lite-04"

  @enforce_keys [:uri, :context, :connection, :session]
  defstruct [:uri, :context, :connection, :session]

  @type t :: %__MODULE__{
          uri: URI.t(),
          context: Context.t(),
          connection: Connection.t(),
          session: Session.t()
        }

  @doc """
  Connects to a native QUIC MOQ Lite draft-04 endpoint.
  """
  @spec connect(String.t() | URI.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(uri, opts \\ []) when is_list(opts) do
    with :ok <- reject_mode(opts),
         {:ok, parsed_uri} <- parse_uri(uri),
         {:ok, {transport, transport_opts}} <- fetch_transport(opts),
         {:ok, context} <- Transport.new(transport, transport_opts),
         timeout <- Keyword.get(opts, :timeout, 5_000),
         {:ok, connection, context} <-
           Transport.connect(context, parsed_uri.host, parsed_uri.port, [alpn: @alpn], timeout),
         {:ok, connection, context} <- Transport.handshake(context, connection, timeout),
         :ok <- verify_alpn(context, connection) do
      {:ok,
       %__MODULE__{
         uri: parsed_uri,
         context: context,
         connection: connection,
         session: Session.new(alpn: @alpn)
       }}
    else
      {:error, reason, _context} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_mode(opts) do
    if Keyword.has_key?(opts, :mode) do
      {:error, {:unsupported_option, :mode}}
    else
      :ok
    end
  end

  defp parse_uri(%URI{} = uri), do: validate_uri(uri)
  defp parse_uri(uri) when is_binary(uri), do: uri |> URI.parse() |> validate_uri()
  defp parse_uri(uri), do: {:error, {:invalid_uri, {:unsupported_input, uri}}}

  defp validate_uri(%URI{scheme: nil}), do: {:error, {:invalid_uri, :missing_scheme}}

  defp validate_uri(%URI{scheme: scheme}) when scheme != "moq-lite",
    do: {:error, {:invalid_uri, {:unsupported_scheme, scheme}}}

  defp validate_uri(%URI{userinfo: userinfo}) when userinfo not in [nil, ""],
    do: {:error, {:invalid_uri, :userinfo_not_supported}}

  defp validate_uri(%URI{host: host}) when host in [nil, ""],
    do: {:error, {:invalid_uri, :missing_host}}

  defp validate_uri(%URI{port: nil}), do: {:error, {:invalid_uri, :missing_port}}

  defp validate_uri(%URI{fragment: fragment}) when fragment not in [nil, ""],
    do: {:error, {:invalid_uri, :fragment_not_supported}}

  defp validate_uri(%URI{} = uri), do: {:ok, uri}

  defp fetch_transport(opts) do
    case Keyword.fetch(opts, :transport) do
      {:ok, {transport, transport_opts}}
      when is_atom(transport) and (is_list(transport_opts) or is_map(transport_opts)) ->
        {:ok, {transport, transport_opts}}

      {:ok, invalid} ->
        {:error, {:invalid_transport, invalid}}

      :error ->
        {:error, :missing_transport}
    end
  end

  defp verify_alpn(context, connection) do
    case Transport.capabilities(context, connection) do
      %Capabilities{alpn: @alpn} ->
        :ok

      %Capabilities{alpn: actual} ->
        {:error,
         Error.new(:unknown_alpn,
           details: %{expected_alpn: @alpn, actual_alpn: actual}
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
