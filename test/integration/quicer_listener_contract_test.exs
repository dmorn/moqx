defmodule MOQX.Integration.QuicerListenerContractTest do
  use MOQX.TransportContract,
    async: false,
    contracts: [:listener_echo],
    tags: [:integration],
    parameterize: [
      %{fixture: MOQX.TransportContract.QuicerListenerFixture}
    ]
end
