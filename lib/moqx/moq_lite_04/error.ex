defmodule MOQX.MOQLite04.Error do
  @moduledoc """
  Structured MOQ Lite draft-04 protocol error.

  The transport layer carries only unsigned integer application error codes.
  This module keeps the MOQ Lite session reducer working with symbolic reasons
  while preserving the exact code sent to or received from the peer.

  MOQ Lite draft-04 does not define a complete application error-code registry.
  The initial code table follows the practical `moq-dev/moq` mapping so reset
  and close actions have deterministic codes from the start.
  """

  @enforce_keys [:reason, :code]
  defstruct [:reason, :code, source: :local, message: nil, details: %{}]

  @type reason ::
          :cancel
          | :required_extension
          | :old
          | :timeout
          | :transport
          | :decode_error
          | :unauthorized
          | :version
          | :unexpected_stream
          | :bounds_exceeded
          | :duplicate
          | :not_found
          | :wrong_size
          | :protocol_violation
          | :unexpected_message
          | :unsupported
          | :encode_error
          | :too_many_parameters
          | :invalid_role
          | :unknown_alpn
          | :dropped
          | :closed
          | :cache_full
          | :frame_too_large
          | :application
          | :remote

  @type source :: :local | :remote

  @type local_reason ::
          :cancel
          | :required_extension
          | :old
          | :timeout
          | :transport
          | :decode_error
          | :unauthorized
          | :version
          | :unexpected_stream
          | :bounds_exceeded
          | :duplicate
          | :not_found
          | :wrong_size
          | :protocol_violation
          | :unexpected_message
          | :unsupported
          | :encode_error
          | :too_many_parameters
          | :invalid_role
          | :unknown_alpn
          | :dropped
          | :closed
          | :cache_full
          | :frame_too_large

  @type t :: %__MODULE__{
          reason: reason(),
          code: non_neg_integer(),
          source: source(),
          message: String.t() | nil,
          details: map()
        }

  @application_code_offset 64

  @reason_to_code %{
    cancel: 0,
    required_extension: 1,
    old: 2,
    timeout: 3,
    transport: 4,
    decode_error: 5,
    unauthorized: 6,
    version: 9,
    unexpected_stream: 10,
    bounds_exceeded: 11,
    duplicate: 12,
    not_found: 13,
    wrong_size: 14,
    protocol_violation: 15,
    unexpected_message: 16,
    unsupported: 17,
    encode_error: 18,
    too_many_parameters: 19,
    invalid_role: 20,
    unknown_alpn: 21,
    dropped: 24,
    closed: 25,
    cache_full: 26,
    frame_too_large: 27
  }

  @code_to_reason Map.new(@reason_to_code, fn {reason, code} -> {code, reason} end)

  @doc """
  Builds a local protocol error.
  """
  @spec new(local_reason() | {:application, non_neg_integer()}, keyword()) :: t()
  def new(reason, opts \\ [])

  def new({:application, application_code}, opts)
      when is_integer(application_code) and application_code >= 0 do
    details =
      opts
      |> Keyword.get(:details, %{})
      |> Map.put(:application_code, application_code)

    %__MODULE__{
      reason: :application,
      code: application_code + @application_code_offset,
      source: :local,
      message: Keyword.get(opts, :message),
      details: details
    }
  end

  def new(reason, opts) when is_atom(reason) do
    case code(reason) do
      {:ok, code} ->
        %__MODULE__{
          reason: reason,
          code: code,
          source: :local,
          message: Keyword.get(opts, :message),
          details: Keyword.get(opts, :details, %{})
        }

      {:error, reason} ->
        raise ArgumentError, "unknown MOQ Lite error reason: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the transport application error code for a known reason or error.
  """
  @spec code(t() | local_reason() | {:application, non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_error_reason, atom()}}
  def code(%__MODULE__{code: code}), do: {:ok, code}

  def code({:application, application_code})
      when is_integer(application_code) and application_code >= 0 do
    {:ok, application_code + @application_code_offset}
  end

  def code(reason) when is_atom(reason) do
    case Map.fetch(@reason_to_code, reason) do
      {:ok, code} -> {:ok, code}
      :error -> {:error, {:unknown_error_reason, reason}}
    end
  end

  @doc """
  Builds an error from a peer-supplied transport application code.
  """
  @spec from_code(non_neg_integer()) :: t()
  def from_code(code) when is_integer(code) and code >= 0 do
    cond do
      Map.has_key?(@code_to_reason, code) ->
        %__MODULE__{reason: Map.fetch!(@code_to_reason, code), code: code, source: :remote}

      code >= @application_code_offset ->
        %__MODULE__{
          reason: :application,
          code: code,
          source: :remote,
          details: %{application_code: code - @application_code_offset}
        }

      true ->
        %__MODULE__{reason: :remote, code: code, source: :remote}
    end
  end
end
