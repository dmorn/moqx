defmodule ProbeLedger do
  @moduledoc """
  Shared format contracts for MOQX transport benchmark artifacts.
  """

  @schema_version "transport-bench-v1"

  @doc """
  Current canonical benchmark record schema version.
  """
  def schema_version, do: @schema_version
end
