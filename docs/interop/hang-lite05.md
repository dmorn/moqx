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
docker run --rm --network moqx44_default \
  -v "$PWD/lib:/workspace/lib:ro" -v "$PWD/test:/workspace/test:ro" \
  -v "$PWD/.tmp/integration-certs:/certs:ro" \
  moqx-moqx-curley-moq-lite-05-test \
  mix test test/integration/curley_moq_lite_05_relay_test.exs \
  test/integration/hang_profiles_test.exs \
  --include integration --include curley_moq_lite_05
```

Build the test image using the existing compose `moqx-curley-moq-lite-05-test` service
before using the Docker command on a fresh machine. These are functional
receiver checks, not network benchmark or browser playback certification.

## Corrected Lite05 completion contract

MOQX 0.9.0 follows the **exclusive** SUBSCRIBE_END boundary deployed by moq.dev:
END is the first sequence that will never be delivered; 0 represents no groups.
The submitted IETF `draft-lcurley-moq-lite-05` section 7.12 still says inclusive.
This is a deliberate, maintainer-approved deviation from that submitted text,
not automatic peer detection or a draft-06 upgrade.

Upstream already tracked the disagreement in
[issue #2309](https://github.com/moq-dev/moq/issues/2309) and fixed its JavaScript
implementation and working draft in
[PR #2333](https://github.com/moq-dev/moq/pull/2333), merge commit
`fccda01366197c9be47e55783a799b438d31c554`. The change explicitly tests Lite05,
including empty tracks and out-of-order group arrival. The pinned relay revision
above already includes this decision. Its source paths are
`rs/moq-net/src/lite/publisher.rs` and `rs/moq-net/src/lite/subscriber.rs`.
The working draft records the correction under -06 because -05 had already
been submitted; the deployed -05 implementation nevertheless uses it.

The earlier MOQX experiment timed out because MOQX still followed the submitted
inclusive wording. That experiment is superseded by the exclusive-boundary
implementation and completion regression suite. See ADR-0014 and code comments
beside both sender and receiver logic.

The native-QUIC fixture verifies END 1 arriving before group 0: the final catalog
is delivered and SubscriptionDone follows. Pinned-relay tests verify immediate
final-catalog completion through finish_subscription and withdraw_track.
The finish_publication check first confirms receiver delivery: namespace withdrawal
can remove the relay route while groups are in flight, so it is not a delivery
barrier. All three publisher paths encode the same exclusive boundary. A separate case finishes an empty track
without delivering or waiting for an invented group 0. Outstanding groups below
the exclusive boundary retain a five-second drain deadline.

No duplicate upstream bug report is needed: #2309 already describes the issue
and #2333 records the chosen resolution. No online-relay deployment claim is made.

## Empty-group epochs, 2026-09-08

`MOQX.publish_empty_group/3` publishes a Group header followed by FIN with zero
frames. It is independent of HANG profile selection. On Lite receivers,
`SubgroupEnded.object_count` distinguishes a complete empty group (zero) from
an object carrying an empty payload (one); a reset is never a complete epoch
boundary, regardless of its count. See the public module documentation for
group ordering, validation, retention and delivery guarantees.

The hermetic public API/transport tests check exact header-only bytes, FIN,
exclusive END, subscriber ranges, retained empty snapshots replacing stale
media, invalid IDs/handles, open-group rejection, withdrawal and track reuse.
Separate public receive tests distinguish empty/non-empty/reset streams. A
cancellation regression confirms that late FIN, data+FIN, reset and newly
arriving groups for a cancelled subscription cannot poison a surviving catalog
subscription. Never-issued subscription IDs still produce a protocol error.

`test/integration/lite_empty_group_test.exs` passed against the pinned local
relay and `cdn.moq.dev` over verified native QUIC. Two subscriptions receive
media at timestamp 1000, an empty group, media at 2000, an empty group, media at
100, then another empty group. Cancelling one leaves the other operational;
a timestamp-only legacy media-end marker remains a one-object group. Immediate
track withdrawal after the final empty group drains that group before
SubscriptionDone. The test uses receiver observations as phase barriers, not
arbitrary sleeps or inferred backend delivery acknowledgements. It does not
assert global group arrival order: production consumers must apply their own
ordering policy as required by ADR-0011.

```sh
MOQX_LITE_ENDPOINT=moql://127.0.0.1:24463/ \
MOQX_LITE_CA_FILE=/path/to/ca.pem \
mise exec -- mix test test/integration/lite_empty_group_test.exs --include integration
```

The public endpoint run used `moql://cdn.moq.dev:443/anon` and the system CA
bundle. Its deployed revision is unknown; only the local relay is pinned.
These tests use synthetic codec payloads and prove wire/event fidelity, not
actual codec decoder reset or playback. End-to-end HANG decoder-reset proof
and Hex publication remain separate release gates for issue #48; no released
API or completed downstream discontinuity support is claimed by this evidence.
