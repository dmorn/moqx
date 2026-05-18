defmodule MOQX.Integration.QuicerSelfPairContractTest do
  use MOQX.TransportContract,
    async: false,
    contracts: [:self_pair, :datagram, :shutdown],
    tags: [:integration],
    parameterize: [
      %{fixture: MOQX.TransportContract.QuicerSelfPairFixture}
    ]
end
