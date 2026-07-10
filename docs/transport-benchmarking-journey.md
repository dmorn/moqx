# The transport benchmarking journey

_How `moqx` went from "we can't trust these numbers" to a measurement stack that
found its own bugs — and what it told us about the QUIC transport before the
MOQT protocol work begins._

This is a narrative record, not a spec. The decisions it references live in
`docs/adr/0005`, `0008`, and especially
[`docs/adr/0009`](adr/0009-layered-benchmark-evidence-contract.md); the runnable
tooling lives in `bench/moqxprobe` (Elixir clients) and `bench/quicprobe` (the Go
reference peer); and how to use it is in
[`docs/agents/transport-testing.md`](agents/transport-testing.md).

## Where we started

We had a working QUIC transport boundary (`MOQX.Transport` over `quicer`/MsQuic)
and a benchmark harness, but the numbers were untrustworthy. The honest framing
at the time was: _"we can't really trust the measurements and it's not even
clear what we're measuring."_ A single "Gbps" figure could have meant client
throughput, receiver throughput, wire bandwidth, path utilization, or just a
Benchee invocation rate — and we'd been reading them interchangeably.

## The realization: closed-loop vs open-loop

The root cause was conceptual, not missing instrumentation. **Benchee is a
closed-loop harness** — it calls the job, waits for it to return, then calls it
again. That measures *service time* and *invocation rate* (`ips`), not
"at offered rate R, what does the receiver get and how late." We'd been reading a
closed-loop service-time number as if it were throughput.

That split became the spine of everything (ADR-0009):

- **Closed-loop** (`bench/stream_clients.exs`, Benchee) ranks client process
  models by service time. Never a bandwidth or saturation claim.
- **Open-loop** (`bench/paced_stream.exs`) offers payloads on a fixed wall-clock
  schedule regardless of completion — so backpressure shows up as backlog, tick
  lag, and a completion deficit instead of being silently absorbed.

And a rule that every number carries its **source layer + window + confidence
tier** (`fake` → `loopback_quic` → `remote_quic_*`), with ambiguous names
(naked `bandwidth`/`goodput`, stream `pkts/s`) forbidden outright.

## What we built (the instruments)

Each layer answers a distinct question, and none of it runs inside the timed
path or a hot telemetry handler:

- **Receiver interval bins** (`quicprobe`) — delivery *shape* over time
  (bytes/streams/datagrams per window + first/last timestamps), so a stall is
  visible instead of averaged away.
- **Out-of-band BEAM/host sampler** — scheduler utilization, run-queue length,
  per-sender-role mailbox depth, sampled by a dedicated low-frequency process.
  This is the instrument that answers _"is the client the bottleneck?"_
- **Open-loop paced sender** — offered vs accepted, backlog, tick lag.
- **Saturation verdict** (issue 58) — a **completion deficit** signal
  (admitted sends that never completed) plus a warmup window, because on a
  buffered QUIC sender the naive tick-lag "coordinated omission" flag both
  false-trips at startup and misses moderate overload. `saturated` is the
  trustworthy verdict; the raw tick-lag flag is documented as a
  sender-scheduling signal only.
- **Send-completion latency, coordinated-omission-corrected** (issue 56) —
  measured from each intent's *scheduled* time (so held-back work isn't omitted)
  with a hand-rolled bounded histogram.
- **End-to-end delivery delay** (issue 59) — `quicprobe` timestamps each object
  (`--object-size`) and we report the delay **above the run minimum**, which
  cancels the unknown sender/receiver clock offset (absolute one-way latency
  across unsynced hosts isn't recoverable).
- **Run manifest + report layer** — every run writes a manifest tying its
  sidecars together; `bench/report.exs` derives named, tier-qualified metrics
  into a `report.md` and refuses to compare across modes/tiers.

## The experiments

Three targets, three regimes.

### reform — a flat ~90 Mbps LAN

`moqx`/`flow_partitions` **saturated the path** — receiver goodput ~90.7 Mbps
(100.8% of the iperf3 UDP baseline) while the sender BEAM sat at **~2.9%
scheduler, run-queue idle**. The open-loop sweep found the knee exactly at the
~90 Mbps ceiling; above it, delivery broke while the sender stayed on schedule
(QUIC buffers the sends) — which is precisely why the completion-deficit signal,
not tick lag, is the honest saturation indicator.

### kim-server-i5 — a ~300 Mbps, lossy Tailscale/WireGuard path

Cross-subnet, so it's routed + WireGuard, not a flat LAN: iperf3 TCP `-P8`
actually *dropped* to 287 Mbps with ~10.8k retransmits, and UDP saw ~56% loss
past ~350 Mbps. Because QUIC's congestion control backs off on loss, the
**sustainable** goodput sat around ~150 Mbps, well below the raw ceiling.

The 4K-shaped sweep (fixed-size objects, sustained 8 s):

| aggregate offered | ≈ 4K streams @ 25 Mbps | completion deficit | e2e delay p99 (above min) | sender BEAM (mean) |
| ---: | ---: | ---: | ---: | ---: |
| **150 Mbps** | ~6 | **0%** | **30–39 ms** | **0.5%** |
| 200 Mbps | ~8 | 33% | ~5.1 s | idle |
| 250 Mbps | ~10 | 66% | ~6 s | ~1.2% |

Below the sustainable rate, delivery is clean and the client is idle; above it,
you get the textbook overrun signature (multi-second queue delay, large
deficit) — a *path* limit backing QUIC off, with the BEAM still doing nothing.

### loopback (silver) — the network removed

To find `moqx`'s own ceiling we deleted the network and ran `quicprobe` locally:

| sender | delivered goodput | BEAM scheduler |
| --- | ---: | ---: |
| open-loop paced (single offer loop) | ~1.4 Gbps | 2–3% |
| closed-loop `flow_partitions` (8 shards) | **~1.5 Gbps** | 9% (peak 15%) |

Two tells: the scheduler **never exceeds ~15%**, and at extreme offered rates
the paced sender's own single offer loop fell 1.5 s behind — it couldn't *issue*
sends fast enough. So on loopback the limit is the **QUIC transport path**
(Quicer/MsQuic send-admission + the single Go receiver draining, all sharing one
host's cores), not the Elixir process model.

## The conclusion

**Across every path tested, `moqx` and the Elixir client are never the
bottleneck.** The limiter is always the network — or, only when the network is
removed, the QUIC transport/NIF at ~1.5 Gbps loopback. Flow/GenStage/the
scheduler have large headroom (idle to ~15%).

And for the actual job — **MOQ is media transport** — this is a non-question. A
4K stream is ~25 Mbps (HEVC/streaming) to ~50 Mbps (H.264/HDR/live). Even the
lossy kim path cleanly carries ~6 concurrent 4K streams at ~30 ms p99 delivery
delay with the client 99.5% idle; a single 4K stream has ~6× headroom. The raw
throughput ceiling matters only for many-Gbps aggregate workloads we don't have.

## Methodology lessons worth keeping

- **Measure, don't guess.** The closed-loop-vs-throughput confusion, the
  ~90 Mbps and ~300 Mbps ceilings, the ~1.5 Gbps transport limit — none were
  what we'd have assumed.
- **The observer must not become the workload.** An early run was capped at
  ~165 Mbps purely by synchronous diagnostics inside the timed path; moving them
  out jumped it to ~844 Mbps. Handler discipline and out-of-band sampling are
  load-bearing (ADR-0005).
- **Tiers keep you honest.** A `fake`/`loopback` number is calibration, not a
  network claim; a closed-loop number ranks implementations, it doesn't measure
  saturation. The report layer enforces this.
- **Adversarial verification caught our own bugs.** The review passes found: a
  coordinated-omission detector that both false-tripped at low rate and missed
  moderate overload; an iperf3 baseline silently dead because it read string
  keys where the producer emitted atoms; and an e2e path that dropped its
  evidence exactly under saturation by only reading "valid" records. Each was
  fixed before it misled a conclusion.
- **The number is only as good as its denominator.** "Delay above the run
  minimum" exists because absolute one-way latency across unsynced clocks is a
  fiction; "sustainable goodput" is not the raw wire rate on a lossy path.

## Where this leaves the project

The transport is validated and **parked**. It is not the constraint for a media
system, and pushing its raw ceiling further (profiling the Quicer send path, a
clean multi-Gbps LAN, parallel receivers) is a deliberate future effort, not a
prerequisite.

The benchmark harness is **not** throwaway — it is the transport test tooling
the protocol work will lean on. `bench/quicprobe` runs as a persistent reference
peer on both `reform` (linux/arm64) and `kim-server-i5` (macOS/x86_64), and the
evidence-contract report layer is ready to measure whatever MOQ Lite draft-04
and MOQT draft-14 send over it.

Next iteration: the actual MOQT-family protocols on top of this boundary. The
wire is fast enough; now we build the media.

## Parked, on purpose

When transport work was wrapped, the `.scratch/transport-layer-foundation`
tracker (a PRD + 60 issues) was retired — the completed work is captured above
and preserved in git history. These items were open and **consciously not
pursued**, because the measurements showed the client is never the bottleneck;
they are recorded here so the intent isn't lost, to be reopened only if a real
need surfaces during protocol work:

- **Deterministic transport failure injection** — a test seam for forcing
  resets/aborts/close deterministically (was `needs-triage`).
- **Priority / flow-control / stats surface** — exposing QUIC stream priority
  and a stats surface through `MOQX.Transport` (was `needs-triage`).
- **Harden transport pressure abstractions**, **improve mixed
  stream/control pressure**, **improve stream throughput** — client-side
  performance work, retired: the client sits idle on every real path; the limit
  is the network or the transport/NIF, not the process model.
- **`stream_owner` sender topology** — superseded; `flow_partitions` is the
  chosen model.
- **Extract shared bench-script helpers** — a genuine dedup across the three
  bench scripts (lease, evidence URL, `write_evidence!`, Benchee hooks), left
  as an opportunistic cleanup for whoever next touches those scripts.
