# Add a pinned local Cloudflare draft-14 relay to integration CI

Status: needs-triage
Type: testing

## Goal

Run subscriber/publisher integration coverage against a pinned local
Cloudflare `moq-rs` draft-14 relay in Docker and CI, while retaining the public
Cloudflare endpoint as separately selected interop evidence.

## Entry conditions

- the subscriber slice is complete;
- the publisher slice has deterministic and live roundtrip coverage;
- the exact `moq-rs` draft-14 revision and build inputs are pinned.

## Constraints

- ExUnit does not implicitly start Docker;
- default `mix test` remains hermetic and fast;
- local relay tests remain distinct from public external smoke tests;
- CI credentials are not required for the local relay path.

## Comments

- 2026-07-13: Created as follow-up after the completed subscriber slice. The
  user requested CI work only after subscriber and publisher support exist.
