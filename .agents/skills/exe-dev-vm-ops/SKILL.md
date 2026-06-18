---
name: exe-dev-vm-ops
description: Set up and operate disposable or persistent remote VMs, especially exe.dev VMs reached through SSH and optionally joined to Tailscale. Use when the user asks to create a VM, install benchmark/dev tools on a VM, find whether a remote VM already exists, check VM health, discover a tailnet IP, run quick smoke checks, or manage routine remote VM ops.
---

# exe.dev VM Ops
Use this for generic remote VM setup and operations. Do not hard-code old VM
names, IPs, regions, tags, ports, or tool versions. Names like
`moqx-quicprobe-fra.exe.xyz`, Tailscale IPs like `100.124.193.59`, and ports
like `55202` are examples only; rediscover current state every time.

## Sources
- For exe.dev syntax, read `https://exe.dev/llms.txt` and linked command docs
  such as `cli-new.md`, `cli-ls.md`, and `cli-ssh.md`.
- For Tailscale setup, auth keys, ephemeral nodes, and diagnostics, read current
  docs at `https://tailscale.com/docs` before changing setup choices.
- Prefer live state over memory: `ssh exe.dev ls -l --json`, direct SSH,
  `tailscale status --json`, and checks on the VM.
- For persistent `iperf3`/`quicprobe` service setup, deployment, restart, cert
  rotation, and verification commands, read [OPS.md](OPS.md).

## Discover
1. List VMs:
   ```bash
   ssh exe.dev ls -l --json
   ```
2. Match by name, tags, comments, region, status, and age. Ask before reusing a
   VM when purpose is ambiguous.
3. Verify reachability and basic health:
   ```bash
   ssh <vm-name>.exe.xyz 'hostname; uname -a; uptime; df -h /'
   ```
4. Check tools and services:
   ```bash
   ssh <vm-name>.exe.xyz 'command -v iperf3 || true; command -v tailscale || true; systemctl is-active tailscaled || true; systemctl is-active moqx-iperf3.service || true'
   ```

## Set Up
1. Pick a descriptive name and tags. Avoid values that will become stale.
2. Create through exe.dev's documented SSH surface. Use stdin for setup scripts
   to avoid remote argument quoting problems:
   ```bash
   printf '%s\n' \
     '#!/usr/bin/env bash' \
     'set -euxo pipefail' \
     'export DEBIAN_FRONTEND=noninteractive' \
     'apt-get update' \
     'apt-get install -y ca-certificates curl jq iperf3' \
     'curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale-install.sh' \
     'sh /tmp/tailscale-install.sh' \
     'systemctl enable --now tailscaled' |
     ssh exe.dev new --name=<name> --tag=<tag> --setup-script=/dev/stdin --json
   ```
3. Verify from inside the VM. Do not assume the setup script completed.
4. If Tailscale is required, enroll with a current ephemeral auth key or have the
   user log in manually. Never print auth keys.
5. For benchmark/dev VMs, keep `iperf3` and `quicprobe` running as services
   instead of using ad hoc `--one-off` servers. Install systemd units such as
   `moqx-iperf3.service` and `moqx-quicprobe.service`; see [OPS.md](OPS.md).
   For iperf3, the core unit shape is:
   - `ExecStart=/usr/bin/iperf3 --server --port <port>`
   - `Restart=always`
   - `WantedBy=multi-user.target`
   Then run `systemctl daemon-reload` and `systemctl enable --now <service>`.

## Health
- Local tailnet view:
  ```bash
  tailscale status --json
  ```
- Discover the current VM tailnet IP by hostname in local status output, or ask
  the VM:
  ```bash
  ssh <vm-name>.exe.xyz 'tailscale status --json; tailscale ip -4'
  ```
- Verify persistent `iperf3` before client tests:
  ```bash
  ssh <vm-name>.exe.xyz 'systemctl is-enabled moqx-iperf3.service; systemctl is-active moqx-iperf3.service; ss -luntp | grep <port>'
  ```
- Verify persistent `quicprobe` with systemd, UDP listener checks, a VM-local
  client smoke, and a local-to-VM Tailscale smoke before claiming QUIC works.
  On Tailscale paths with a 1280 route MTU, run both quicprobe server and
  client with `--initial-packet-size 1200`; see [OPS.md](OPS.md).
- Run short smoke tests sequentially; one `iperf3` server handles only one active
  test at a time:
  ```bash
  iperf3 --client <tailnet-ip> --port <port> --time 2 --json
  iperf3 --client <tailnet-ip> --port <port> --udp --bitrate 5M --time 2 --json
  ```
- Treat these as connectivity smokes, not benchmarks. Record path mode when
  available; a relay path is not equivalent to a direct-path baseline.

## Ops Rules
- Read-only first for unfamiliar VMs. Do not delete, resize, restart, or mutate
  services until the user asks or the purpose is clear.
- Prefer direct `ssh <vm-name>.exe.xyz ...` once the VM name is known.
- Keep secrets out of logs, command output, shell history, and repo files.
- After changing services, verify with `command -v`, versions, `systemctl`,
  socket listeners, and one minimal end-to-end smoke.
- When reporting results, include VM name, provider/region if known, current
  tailnet IP, service state, what was checked, and what remains uncertain.
