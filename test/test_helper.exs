# Exclude integration tests by default if relay isn't available
exclusions =
  if MOQX.Test.Relay.available?() do
    []
  else
    [integration: true]
  end

# External relay tests are opt-in via MOQX_EXTERNAL_RELAY=1
exclusions =
  if System.get_env("MOQX_EXTERNAL_RELAY") do
    exclusions
  else
    [{:external_relay, true} | exclusions]
  end

ExUnit.start(exclude: exclusions)
