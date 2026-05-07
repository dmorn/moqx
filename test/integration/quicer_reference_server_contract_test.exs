defmodule MOQX.Integration.QuicerReferenceServerContractTest do
  use MOQX.TransportContract,
    async: false,
    contracts: [:client_echo],
    tags: [:integration],
    parameterize: [
      %{fixture: MOQX.TransportContract.QuicerReferenceServerFixture}
    ]
end
