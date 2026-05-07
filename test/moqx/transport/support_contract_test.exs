defmodule MOQX.Transport.SupportContractTest do
  use MOQX.TransportContract,
    contracts: [:client_echo, :self_pair, :datagram],
    parameterize: [
      %{fixture: MOQX.TransportContract.SupportFixture}
    ]
end
