# HANG and MoQ Lite 05 reference pins

The HANG specification is `drafts/draft-lcurley-moq-hang.md` in
[moq-dev/moq at fd477082c43c3c0738fb62d077d85ea078f10045](https://github.com/moq-dev/moq/blob/fd477082c43c3c0738fb62d077d85ea078f10045/drafts/draft-lcurley-moq-hang.md).
The same commit pins the existing native QUIC relay harness, Rust `hang` 0.20.10
and JavaScript `@moq/hang` 0.4.2. Package versions alone do not replace the commit
pin. The moving doc.moq.dev page is not the version contract.

Wire discovery follows `draft-lcurley-moq-lite-05` ANNOUNCE_REQUEST,
ANNOUNCE_OK and ANNOUNCE_BROADCAST. The HANG document retains older
ANNOUNCE_PLEASE/ANNOUNCE prose; these are not additional wire messages.
Native QUIC retains ALPN `moq-lite-05`; draft-06 is outside this feature.

The pinned catalog includes audio/video rendition maps, WebCodecs configuration,
hex decoder descriptions, base64 CMAF initialization, relative broadcast
references, unknown extensions, and raw-DEFLATE sync-flushed `catalog.json.z`.
Timeline metadata is preserved; timeline retrieval and media decoding remain
application responsibilities.

## Verification, 2026-09-07

The support-transport suite exercises raw/profile composition, scoped handles,
malformed-update recovery, replacement and track diffs, discovery and final
subscription draining. Public codec tests cover independently encoded DEFLATE,
expansion limits, initialization bytes, relative addressing and extensions.

Native QUIC with the pinned relay verifies concurrent plain/compressed catalog
receivers, retained late snapshots, live replacement, initial/add/remove
broadcast discovery, cancellation/resubscription and abrupt publisher owner exit.
The relay's default reconnect linger delays abrupt-loss withdrawal by five
seconds; the test allows ten seconds. The official pinned CLI receives the HANG
catalog and exports the exact H.264 frame in the existing interoperability test.

Commands (from the repository root, after generating the standard loopback
certificates with `scripts/gen-loopback-certs.sh`):

```sh
docker compose -p moqx44 -f docker-compose.integration.yml up -d curley-moq-lite-05-relay
mise exec -- mix test
mise exec -- mix credo --strict
mise exec -- mix test test/integration/hang_profiles_test.exs --include integration
docker run --rm --network moqx44_default \
  -v "$PWD/lib:/workspace/lib:ro" -v "$PWD/test:/workspace/test:ro" \
  -v "$PWD/.tmp/integration-certs:/certs:ro" \
  moqx-moqx-curley-moq-lite-05-test \
  mix test test/integration/curley_moq_lite_05_relay_test.exs \
  --include integration --include curley_moq_lite_05
```

Build the test image using the existing compose `curley-moq-lite-05-test` service
before using the Docker command on a fresh machine. These are functional
receiver checks, not network benchmark or browser playback certification.

## Known peer completion gap

Published Lite05 section 7.12 defines the SUBSCRIBE_END group as **inclusive**.
The pinned Curley implementation instead emits/consumes an **exclusive** group
boundary (`moq-lite/src/ietf/publisher.rs` and `subscriber.rs`). MOQX preserves
published draft semantics. An experiment sending one final catalog and
immediately finishing through this relay delivered the catalog but then timed
out waiting for the extra group implied by the relay's END value.

The native-QUIC fixture separately verifies a conforming inclusive END arriving
before the final Group stream: CatalogReceived is followed by SubscriptionDone.
Outstanding groups have a five-second drain deadline. Successful catalog/media
exchange with this peer does **not** certify its terminal subscription boundary.
No automatic peer inference, ALPN relabeling, or compatibility variant is added.

The public API change is prepared for the next release; this branch does not
publish a Hex release. Downstream consumers should use a released version after
merge, or explicitly pin the reviewed commit for evaluation.
