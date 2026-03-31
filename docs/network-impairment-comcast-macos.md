# macOS network impairment testing with Comcast + iperf3

This note records the current state of trying to use [Comcast](https://github.com/tylertreat/comcast) on macOS as a simple way to reproduce bad network conditions for local testing.

The motivating use case is to benchmark and compare **moqx** against other protocols under conditions like:

- added latency
- packet loss
- bandwidth limits
- UDP traffic shaping

## Why Comcast

We evaluated a few options:

- [`Shopify/toxiproxy`](https://github.com/Shopify/toxiproxy)
- [`tylertreat/comcast`](https://github.com/tylertreat/comcast)
- Apple Network Link Conditioner wrappers

For `moqx`, **Comcast** is the more relevant candidate because it works at a lower level through macOS packet filter / dummynet tooling and is a better fit for **UDP-based** testing.

`toxiproxy` is excellent for scripted impairment, but it is mainly a TCP proxy, which makes it a worse fit for lower-level UDP comparisons.

## Environment used during investigation

Observed on this machine:

- macOS `26.4`
- Darwin kernel `25.4.0`
- `iperf3` installed at `/opt/homebrew/bin/iperf3`
- `pfctl` present at `/sbin/pfctl`
- `dnctl` present at `/usr/sbin/dnctl`
- `ipfw` not present

## What worked

### 1. Baseline UDP loopback test with iperf3

A plain loopback UDP test works fine.

Example:

```bash
iperf3 -s -B 127.0.0.1 -p 5207
iperf3 -c 127.0.0.1 -p 5207 -u -b 10M -t 3
```

Observed baseline characteristics were roughly:

- ~10 Mbit/s achieved
- 0% loss
- near-zero jitter

This is useful as a control before adding shaping.

### 2. Comcast dry-run on macOS

Comcast can generate the expected `pfctl` / `dnctl` commands for macOS.

For a UDP test on loopback, the desired shape is conceptually:

- `lo0`
- `80ms` added latency
- `5000 Kbit/s` bandwidth cap
- `2%` packet loss
- UDP only
- target port `5207`

The expected command sequence is:

```bash
sudo pfctl -E
(cat /etc/pf.conf && echo "dummynet-anchor \"mop\"" && echo "anchor \"mop\"") | sudo pfctl -f -
echo $'dummynet in on lo0 all pipe 1' | sudo pfctl -a mop -f -
sudo dnctl pipe 1 config delay 80ms bw 5000Kbit/s plr 0.0200 mask dst-port 5207 proto udp
sudo dnctl pipe 1 config delay 80ms bw 5000Kbit/s plr 0.0200 mask src-port 5207 proto udp
```

That should be enough to shape inbound UDP traffic on `lo0` for the `iperf3` port.

## What did **not** work from the agent session

The agent session did **not** have passwordless `sudo`, so it could not actually:

- add a loopback alias with `ifconfig`
- enable and configure `pfctl`
- configure dummynet with `dnctl`

For example, attempts like this failed without elevated privileges:

```bash
ifconfig lo0 alias 127.0.0.2 up
```

and direct `dnctl` access reported an operation not permitted error without `sudo`.

So the work below should be run manually in a local terminal with admin access.

## Important Comcast caveat on macOS

There appears to be an important difference between:

- the installed release from `go install github.com/tylertreat/comcast@latest`
- a local build from the cloned source tree

### Release build issue

The installed binary generated this rule during `--dry-run`:

```bash
echo $'dummynet in all pipe 1' | sudo pfctl -a mop -f -
```

That appears to ignore `--device lo0`.

### Local source build behavior

A local build from source generated the correct device-specific rule:

```bash
echo $'dummynet in on lo0 all pipe 1' | sudo pfctl -a mop -f -
```

So for macOS loopback testing, prefer a **local source build** and verify the generated rule with `--dry-run` before relying on it.

## Recommended manual procedure

### 1. Clone and build Comcast locally

```bash
git clone https://github.com/tylertreat/comcast /tmp/comcast
cd /tmp/comcast
```

The repository currently includes a self-referential `require` in `go.mod`, so we removed that line before building locally:

```bash
python3 - <<'PY'
from pathlib import Path
p=Path('/tmp/comcast/go.mod')
s=p.read_text()
s='\n'.join([line for line in s.splitlines() if 'require github.com/tylertreat/comcast' not in line])+'\n'
p.write_text(s)
PY
```

Then build:

```bash
go build -o /tmp/comcast-local-bin .
```

Verify the generated commands:

```bash
/tmp/comcast-local-bin \
  --device=lo0 \
  --latency=80 \
  --target-bw=5000 \
  --packet-loss=2% \
  --target-proto=udp \
  --target-port=5207 \
  --dry-run
```

Confirm that the `pfctl` rule includes:

```bash
dummynet in on lo0 all pipe 1
```

## 2. Add a loopback alias

Use a dedicated loopback address so tests are easy to isolate.

```bash
sudo ifconfig lo0 alias 127.0.0.2 up
```

## 3. Run a baseline UDP iperf3 server/client pair

In one terminal:

```bash
iperf3 -s -B 127.0.0.2 -p 5207
```

In another:

```bash
iperf3 -c 127.0.0.2 -p 5207 -u -b 10M -t 5
```

Record:

- bitrate
- jitter
- packet loss

## 4. Apply Comcast shaping

```bash
sudo /tmp/comcast-local-bin \
  --device lo0 \
  --latency 80 \
  --target-bw 5000 \
  --packet-loss 2% \
  --target-proto udp \
  --target-port 5207
```

## 5. Run the shaped UDP test

```bash
iperf3 -c 127.0.0.2 -p 5207 -u -b 10M -t 5
```

Compare against the baseline.

## 6. Reset everything

```bash
sudo /tmp/comcast-local-bin --device lo0 --stop
sudo ifconfig lo0 -alias 127.0.0.2
```

## Suggested profiles for moqx comparisons

A few candidate profiles to try:

### Mild Wi‑Fi-ish

```text
latency: 20ms
bandwidth: 30000 Kbit/s
packet loss: 0.2%
```

### Poor Wi‑Fi / mobile handoff

```text
latency: 80ms
bandwidth: 5000 Kbit/s
packet loss: 2%
```

### Bad mobile network

```text
latency: 200ms
bandwidth: 1000 Kbit/s
packet loss: 5%
```

### Very degraded network

```text
latency: 500ms
bandwidth: 250 Kbit/s
packet loss: 10%
```

## How this can help moqx

This setup gives us a repeatable local harness to compare:

- `moqx` vs other protocols
- TCP vs UDP-based transport assumptions
- throughput under loss
- behavior under constrained bandwidth
- jitter/loss sensitivity for live or relay-style workloads

Possible next steps in this repo:

1. add a small script under `scripts/` to automate Comcast profile setup
2. add benchmark notes capturing `moqx` behavior under each profile
3. compare against `iperf3`, QUIC-based tools, or WebTransport/WebRTC-adjacent baselines
4. export results as CSV/JSON for plotting

## Open questions

Before relying on this heavily, we should validate a few things on current macOS versions:

- whether Comcast’s `pfctl`/`dnctl` approach remains stable across macOS releases
- whether shaping on `lo0` matches the behavior we care about for real deployments
- whether we need packet reordering/corruption beyond latency/loss/bandwidth
- whether a custom direct `pfctl`/`dnctl` script would be more reliable than Comcast itself

## Summary

Current recommendation:

- use **Comcast** for local UDP/macOS impairment experiments
- build it **from source locally** rather than relying on the installed release binary
- validate the generated `pfctl` rule with `--dry-run`
- use `iperf3` on a loopback alias as the initial smoke test
- then reuse the same shaping setup to compare `moqx` with other protocols under controlled bad-network conditions
