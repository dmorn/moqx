# Exclude integration tests by default if relay isn't available
exclusions =
  if MOQX.Test.Relay.available?() do
    []
  else
    [integration: true]
  end

ExUnit.start(exclude: exclusions)
