# Add a pinned local Cloudflare draft-14 relay to integration CI

Status: done
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
- 2026-07-13: Implemented a Docker-first harness with a relay image built from
  Cloudflare `moq-rs` revision
  `69302d3dc2422e93b8a1d62f853a6759aa9e5468` on branch
  `draft-ietf-moq-transport-14`. The relay's current `main` negotiates a newer
  ALPN, so it is intentionally not used as the draft-14 build source. Rust,
  Debian, and Elixir runner base images are pinned by immutable digest.
- 2026-07-13: Added a containerized MOQX test runner on the Compose network.
  This avoids Docker Desktop host-UDP forwarding differences while preserving
  the actual boundary under test: two public MOQX clients, quicer, QUIC, and a
  separate real relay process. ExUnit remains Docker-agnostic.
- 2026-07-13: The roundtrip publishes a catalog and retained media object,
  subscribes to both through another connection, verifies the object payload,
  and completes the publication. A late relay namespace cancellation is now
  idempotent after local completion.
- 2026-07-13: The pinned relay currently emits `stream_count = 0` from its
  relay-side `Subscribed::drop` path even after forwarding one subgroup stream;
  upstream marks this field with a TODO. The integration assertion records
  both the reported zero and the one stream MOQX actually processed rather than
  misrepresenting the relay's behavior.
- 2026-07-13: `scripts/run_moq_rs_integration.sh` owns startup, test execution,
  and cleanup locally and in the dedicated GitHub Actions job. Future Moqtail
  and MOQ Lite relays get their own pinned service/test/runner using this same
  harness boundary.
