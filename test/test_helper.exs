# Compile test support modules
Code.require_file("support/relay.ex", __DIR__)
Code.require_file("support/auth.ex", __DIR__)

# Exclude integration tests by default if relay isn't available
exclusions =
  if MOQX.Test.Relay.available?() do
    []
  else
    [integration: true]
  end

ExUnit.start(exclude: exclusions)
