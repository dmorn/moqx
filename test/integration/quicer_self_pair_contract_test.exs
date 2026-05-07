defmodule MOQX.Integration.QuicerSelfPairContractTest do
  use MOQX.TransportContract,
    async: false,
    contracts: [:self_pair, :datagram],
    tags: [:integration],
    parameterize: [
      %{fixture: MOQX.TransportContract.QuicerSelfPairFixture}
    ]
end
