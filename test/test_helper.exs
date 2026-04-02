# Integration tests are tagged :integration and excluded by default.
# External relay tests are additionally tagged :external_relay.
exclusions = [integration: true]

exclusions =
  if System.get_env("MOQX_EXTERNAL_RELAY") do
    exclusions
  else
    [{:external_relay, true} | exclusions]
  end

ExUnit.start(exclude: exclusions)
