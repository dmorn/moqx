defmodule MOQX.Catalog.Compression do
  @moduledoc false
  @default_limit 1_048_576
  @flush <<0, 0, 255, 255>>

  def decode(payload, options) do
    limit = Keyword.get(options, :max_bytes, @default_limit)
    encoded_limit = Keyword.get(options, :max_encoded_bytes, @default_limit)

    with :ok <- check_limit(limit),
         :ok <- check_limit(encoded_limit),
         :ok <- bounded(payload, encoded_limit) do
      decompress(payload, Keyword.get(options, :compression, :none), limit)
    end
  end

  defp decompress(payload, :none, limit),
    do: with(:ok <- bounded(payload, limit), do: {:ok, payload})

  defp decompress(payload, :deflate, limit), do: inflate(payload, limit)
  defp decompress(_payload, _compression, _limit), do: error(:unsupported_compression)

  def encode(payload, options) do
    limit = Keyword.get(options, :max_bytes, @default_limit)
    encoded_limit = Keyword.get(options, :max_encoded_bytes, @default_limit)

    with :ok <- check_limit(limit),
         :ok <- check_limit(encoded_limit),
         :ok <- bounded(payload, limit),
         {:ok, encoded} <- compress(payload, Keyword.get(options, :compression, :none)),
         :ok <- bounded(encoded, encoded_limit),
         do: {:ok, encoded}
  end

  defp compress(payload, :none), do: {:ok, payload}
  defp compress(payload, :deflate), do: deflate(payload)
  defp compress(_payload, _compression), do: error(:unsupported_compression)

  defp inflate(payload, limit) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_chunks(z, :zlib.safeInflate(z, payload <> @flush), limit, [])
    catch
      :error, _reason -> error(:invalid_compression)
    after
      :zlib.close(z)
    end
  end

  defp inflate_chunks(z, {status, bytes}, remaining, chunks)
       when status in [:continue, :finished] do
    size = IO.iodata_length(bytes)

    cond do
      size > remaining -> error(:too_large)
      status == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([bytes | chunks]))}
      true -> inflate_chunks(z, :zlib.safeInflate(z, <<>>), remaining - size, [bytes | chunks])
    end
  end

  defp inflate_chunks(_z, _result, _remaining, _chunks), do: error(:invalid_compression)

  defp deflate(payload) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      bytes = IO.iodata_to_binary(:zlib.deflate(z, payload, :sync))
      {:ok, binary_part(bytes, 0, byte_size(bytes) - 4)}
    after
      :zlib.close(z)
    end
  end

  defp check_limit(limit) when is_integer(limit) and limit > 0, do: :ok
  defp check_limit(_limit), do: error(:invalid_limit)
  defp bounded(payload, limit) when byte_size(payload) <= limit, do: :ok
  defp bounded(_payload, _limit), do: error(:too_large)
  defp error(reason), do: {:error, %MOQX.Catalog.Error{path: [], reason: reason}}
end
