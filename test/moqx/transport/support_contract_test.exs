defmodule MOQX.Testing.TransportContractTest do
  use MOQX.TransportContract,
    contracts: [:client_echo, :self_pair, :datagram, :shutdown],
    parameterize: [
      %{fixture: MOQX.TransportContract.SupportFixture}
    ]
end
