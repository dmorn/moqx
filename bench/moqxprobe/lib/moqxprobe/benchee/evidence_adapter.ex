defmodule MOQXProbe.Benchee.EvidenceAdapter do
  @moduledoc false

  alias MOQXProbe.Benchee.Evidence
  alias MOQXProbe.Benchee.RunReceipt

  @callback collect(RunReceipt.t(), keyword()) :: {:ok, Evidence.t()} | {:error, term()}
end
