defmodule MOQX.Protocol.Resolver do
  @moduledoc """
  Resolves an explicit protocol selection to its implementation module.

  Endpoint hostnames are deliberately absent from this API. Built-in IDs are
  conveniences; callers may also provide a module implementing
  `MOQX.Protocol`.
  """

  alias MOQX.Protocol

  @built_ins %{
    cloudflare_draft_14: MOQX.Protocol.CloudflareDraft14,
    draft_16: MOQX.Protocol.Draft16,
    moq_lite_05: MOQX.Protocol.MOQLite05
  }

  @doc "Returns the built-in protocol identifiers."
  @spec ids() :: [Protocol.id()]
  def ids, do: @built_ins |> Map.keys() |> Enum.sort()

  @doc "Resolves a built-in identifier or a complete custom implementation module."
  @spec fetch(Protocol.id() | module()) ::
          {:ok, module()} | {:error, :unknown_protocol | :invalid_protocol_implementation}
  def fetch(selection) when is_atom(selection) do
    case Map.fetch(@built_ins, selection) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        if Protocol.implementation?(selection) do
          {:ok, selection}
        else
          resolver_error(selection)
        end
    end
  end

  defp resolver_error(selection) do
    if Code.ensure_loaded?(selection) do
      {:error, :invalid_protocol_implementation}
    else
      {:error, :unknown_protocol}
    end
  end
end
