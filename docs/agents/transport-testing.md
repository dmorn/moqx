# Transport testing & benchmarking

How this repo verifies and measures the QUIC transport. Read this before
touching `MOQX.Transport`, `bench/moqxprobe`, or `bench/quicprobe`.

## Read first

- `docs/adr/0009-*` — the layered **benchmark evidence contract**: measurement
  modes, metric naming, confidence tiers. This governs how numbers are reported.
- `docs/adr/0005-*` — telemetry event bus and hot-path handler discipline.
- `docs/adr/0008-*` — functional `Conn`/`Stream` ownership; send completion is
  backend credit, not delivery.
- `CONTEXT.md` — transport vocabulary (Finish Sending, Abort Sending, etc.).
- `bench/moqxprobe/README.md` — the runnable benchmark loop.

## Three kinds of checks

1. **Contract / unit tests** (`mix test`) — deterministic and hermetic. They run
   against the in-repo `MOQX.Transport.Support` backend, never a real socket.
   This is where transport behaviour is pinned down.
2. **Integration tests** (`mix test --only integration`) — real QUIC over the
   `MOQX.Transport.Quicer` backend, excluded by default. They use the docker
   harness (`docker-compose.integration.yml`); certificates come from
   `scripts/gen-loopback-certs.sh` (long-lived, localhost only).
3. **Benchmarks** (`bench/moqxprobe` + `bench/quicprobe`) — separate Mix/Go
   projects, **not** part of `mix test`. Covered below.

## The benchmark loop (ADR-0009)

Two measurement **modes** that must never be compared to each other:

- **Closed-loop** — `bench/stream_clients.exs` (Benchee). Ranks client process
  models by per-invocation service time. It is *not* a bandwidth or
  saturation claim.
- **Open-loop** — `bench/paced_stream.exs`. Offers payloads on a fixed
  wall-clock schedule regardless of completion, and measures offered-vs-accepted,
  the `saturated` verdict (completion deficit / backlog — the trustworthy
  saturation signal), and send-completion latency (corrected + uncorrected).

Confidence **tiers** qualify every number: `fake` (process model only) →
`loopback_quic` (local QUIC calibration) → `remote_quic_*` (real path).

**Targets** (a `--target` flag):

- `fake` — in-process, no sockets; isolates the client process model.
- `quicprobe` — the Go reference peer in `bench/quicprobe`, run locally
  (loopback) or on a remote host.

## The reference peer (`bench/quicprobe`) and `reform`

`quicprobe` is a Go QUIC server that receives and reports receiver-side
delivery **evidence** (bytes, streams, datagrams, interval bins, timestamps)
over an always-on HTTP evidence API. `reform` is the persistent remote target:

- systemd service `moqx-quicprobe.service` (passwordless sudo on the box).
- Release layout: `/opt/moqx-bench/quicprobe/current -> releases/<sha>`, TLS in
  `/opt/moqx-bench/quicprobe/tls`.
- Ports: QUIC UDP `55433`, evidence HTTP `55434`, iperf3 `55202`; TLS
  servername `reform`; client CA at `/private/tmp/reform-quicprobe-ca.pem`.

**Deploying a new quicprobe to a remote target:** cross-build
(`GOOS=linux GOARCH=arm64 go build`), copy to a new `releases/<sha>` dir,
repoint the `current` symlink atomically (`ln -sfn`), `systemctl restart`, and
verify the new build via the evidence API `/healthz` and a probe. The old
release stays for rollback. Receiver-side evidence (interval bins, e2e latency)
requires the target to run a quicprobe new enough to emit it.

## Evidence, manifest, and report

- A run writes sidecars + a `manifest.json` under `bench/moqxprobe/results/<run>/`
  (`--evidence-output`, `--host-samples-output`, `--paced-output`,
  `--manifest-output`). Delivery evidence is collected out-of-band, never inside
  the timed path.
- `bench/report.exs --run-dir <dir>` derives named, windowed, tier-qualified
  metrics into `report.md` (`MOQXProbe.Report`). It refuses ambiguous names
  (no naked `bandwidth`/`goodput`, no stream `pkts/s`) and warns on cross-mode
  or wrong-tier claims.

## Running a measurement session

The established flow (deploy the current quicprobe to the remote target first if
you need receiver-side evidence):

1. **iperf3 preflight** — TCP + UDP path baseline; establishes the ceiling that
   the sweep brackets.
2. **Closed-loop sanity run** — confirms the path and delivery are healthy.
3. **Open-loop rate sweep** — rates bracketing the path ceiling; find the knee
   where `saturated` trips and delivery stops reconciling.
4. **Report + synthesize** — one `report.md` per run; compare against the
   baseline, and qualify every claim by its tier.

## Before committing (CLAUDE.md)

`mix format`, `mix test`, `mix credo --strict` for Elixir (root and
`bench/moqxprobe`); `go build ./... && go vet ./... && go test ./...` for
`bench/quicprobe`. Keep pure logic in modules (unit-tested); keep scripts thin.
No `Application` env as config.
