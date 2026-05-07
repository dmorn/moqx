defmodule MOQX.Transport.SupportContractTest do
  use MOQX.TransportContract,
    contracts: [:client_echo, :self_pair],
    parameterize: [
      %{fixture: MOQX.TransportContract.SupportFixture}
    ]
end
