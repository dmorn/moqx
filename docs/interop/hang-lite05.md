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
actual codec decoder reset or playback. The separate browser experiment below
provides that narrower decoder-reset proof using actual Opus packets. Hex
publication remains a release gate for issue #48; no released API or completed
downstream discontinuity support is claimed by this evidence.

### Actual pinned reference Opus decoder reset

A separate observation-only browser harness used Chrome **152.0.7977.76** and
the pinned reference `moq-watch`, without modifying its implementation. The
publisher used MOQX public APIs directly, not plugin wire construction. Its
synthetic Opus fixture SHA-256 was
`268347d3b6167caa995fe4ae636d95cc7f9b3529214b488807a90dce3e454358`.
FFprobe extracted the first 50 packets, each producing 960 decoded frames per
channel at 48 kHz. The same real codec packets were sent in three groups with
timestamp ranges 5,000,000..5,980,000, 10,000,000..10,980,000, and 0..980,000
microseconds. `publish_empty_group/3` inserted group 1 between media groups 0/2
and group 3 between media groups 2/4. The HANG catalog declared Opus, stereo,
48 kHz, and the legacy container.

The harness wrapped browser `AudioDecoder` only to observe native `reset`,
`configure`, `decode`, and actual `AudioData` output calls. It also observed the
reference container's returned discontinuity metadata. It did not simulate
decoder output or inject a reset. Epoch advancement waited for all 50 decoded,
non-silent outputs from the preceding epoch; within each epoch, packets used
the media clock. Neither phase barrier nor pacing adds a protocol delay.

The local run used the same pinned relay image, browser WebTransport on
`https://127.0.0.1:24464/`, and native MOQX on `moql://127.0.0.1:24464/`.
Browser certificate hashing and native CA verification were enabled. It
observed exactly **150 AudioData outputs**, **two native decoder resets** after
outputs 50 and 100, and **three Opus configurations**. Each epoch's first decoded
timestamp matched its new origin, including the backward jump to zero. PCM
peaks reached approximately **0.08912**; there were no decoder errors, and the
publisher exited normally. This proves a real pinned HANG audio consumer
resets and resumes decoding across the published empty-group boundaries; it
does not certify H.264/CMAF discontinuities or audiovisual synchronization.

The public endpoint also produced an equivalent 150-output/two-reset passing
trace with system-trusted TLS, but evidence is **mixed**, not a claim of stable
public interoperability. One preceding public full-packet run observed reset
counts at outputs 50, 100, and 100, followed by a synchronous `AudioDecoder.decode`
`DataError` at the backward epoch and no third-epoch output. A traced rerun
passed without changing publisher or reference logic. The precise cause of
that intermittent failure is not established: these observations do not
attribute it to MOQX, the relay, browser, or reference reorder/decoder logic.
Do not convert the passing retry into a claim that the failure was fixed.

Task-local runnable proof material is retained at
`/private/tmp/moqx-epoch-browser.NVS4p1`: `publish.exs`, `main.ts`, `check.mjs`,
and `vite.config.ts`. `local-complete-proof.json` and `public-trace-proof.json`
contain the exact passing decoder and container observations. The failed
full-packet run is preserved in the execution transcript (no JSON artifact was
written by that earlier checker version). The weaker initial public run,
`public-proof.json`, used a 20-output phase threshold and is not the full-packet
proof. The local server uses port 5187; no shared reference or plugin files
were modified by the experiment.
