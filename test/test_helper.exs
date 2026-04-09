# Integration tests are tagged and excluded by default.
# Use `mix test --include integration` and/or
# `mix test --include public_relay_live` to opt in.
ExUnit.start(exclude: [integration: true, public_relay_live: true])
