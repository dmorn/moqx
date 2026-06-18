# Remote VM Ops

Generic commands for exe.dev-style VMs that host benchmark/dev services. Values
such as `moqx-quicprobe-fra.exe.xyz`, `100.124.193.59`, `55202`, and `55433`
are examples only. Rediscover current VM names, tailnet IPs, ports, paths, and
versions before acting.

## Discover

```bash
ssh exe.dev ls -l --json
ssh <vm-name>.exe.xyz 'hostname; uname -a; uptime; df -h /'
ssh <vm-name>.exe.xyz 'tailscale status --json; tailscale ip -4'
ssh <vm-name>.exe.xyz 'command -v iperf3; command -v go || true; /opt/moqx-bench/quicprobe/current/bin/quicprobe 2>&1 | head -1'
```

## Persistent iperf3

Keep `iperf3` running under systemd for quick path checks.

```ini
[Service]
ExecStart=/usr/bin/iperf3 --server --port <iperf-port>
Restart=always
```

Verify and smoke:

```bash
ssh <vm>.exe.xyz 'systemctl is-enabled moqx-iperf3.service; systemctl is-active moqx-iperf3.service; ss -luntp | grep <iperf-port>'
iperf3 --client <tailnet-ip> --port <iperf-port> --time 2 --json
iperf3 --client <tailnet-ip> --port <iperf-port> --udp --bitrate 5M --time 2 --json
```

Run TCP and UDP tests sequentially. One `iperf3` server handles one active test
at a time.

## Persistent quicprobe

Use the repo-built `quicprobe` binary at
`/opt/moqx-bench/quicprobe/current/bin/quicprobe`. The VM may also have Go
installed, which is useful for emergency remote builds when source is present,
but the normal path is to deploy a built artifact from the repo.

The server needs a cert/key and should write receiver-evidence JSONL:

```ini
[Service]
ExecStart=/opt/moqx-bench/quicprobe/current/bin/quicprobe server --addr :<quic-port> --cert /opt/moqx-bench/quicprobe/tls/server.pem --key /opt/moqx-bench/quicprobe/tls/server-key.pem --stats-output /var/lib/moqx-quicprobe/quicprobe-evidence.jsonl --initial-packet-size 1200
Restart=always
ReadWritePaths=/var/lib/moqx-quicprobe
```

Use `--initial-packet-size 1200` for quicprobe over Tailscale or another path
with a 1280 MTU. quic-go's default 1280-byte Initial becomes too large once
IPv4/UDP headers are added, and normal UDP sockets set DF. The matching client
commands below must also include `--initial-packet-size 1200`.

If the tailnet IP or DNS names change, rotate the cert so its SANs match the
current endpoint used by clients. Keep `ca.pem` available for clients.

Generate/rotate certs on the VM:

```bash
ssh <vm>.exe.xyz 'set -euo pipefail
TS_IP=$(tailscale ip -4 | head -1)
CERT_DIR=/opt/moqx-bench/quicprobe/tls
sudo install -d -m 0755 "$CERT_DIR" /var/lib/moqx-quicprobe
TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
cat > "$TMP/server.ext" <<EOF
subjectAltName=DNS:localhost,DNS:<vm-short-name>,DNS:<vm>.exe.xyz,IP:127.0.0.1,IP:${TS_IP}
extendedKeyUsage=serverAuth
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=<vm-short-name>-ca" -keyout "$TMP/ca-key.pem" -out "$TMP/ca.pem"
openssl req -newkey rsa:2048 -nodes -subj "/CN=<vm-short-name>" -keyout "$TMP/server-key.pem" -out "$TMP/server.csr"
openssl x509 -req -in "$TMP/server.csr" -CA "$TMP/ca.pem" -CAkey "$TMP/ca-key.pem" -CAcreateserial -days 30 -extfile "$TMP/server.ext" -out "$TMP/server.pem"
sudo install -m 0644 "$TMP/ca.pem" "$TMP/server.pem" "$CERT_DIR/"
sudo install -m 0600 "$TMP/server-key.pem" "$CERT_DIR/server-key.pem"'
```

Deploy a new local artifact and restart:

```bash
just bench-transport-build-quicprobe linux_x86_64
artifact=$(just --quiet bench-transport-quicprobe-artifact-rel linux_x86_64)
release_id=$(basename "$artifact" .tar.gz)
scp "bench/moqxprobe/$artifact" <vm>.exe.xyz:/tmp/
ssh <vm>.exe.xyz "set -euo pipefail
sudo install -d -m 0755 /opt/moqx-bench/quicprobe/releases/$release_id
sudo tar -xzf /tmp/$release_id.tar.gz -C /opt/moqx-bench/quicprobe/releases/$release_id
sudo chmod -R a+rX /opt/moqx-bench/quicprobe/releases/$release_id
sudo chmod 0755 /opt/moqx-bench/quicprobe/releases/$release_id/bin/quicprobe
sudo ln -sfn /opt/moqx-bench/quicprobe/releases/$release_id /opt/moqx-bench/quicprobe/current
sudo systemctl restart moqx-quicprobe.service
systemctl is-active moqx-quicprobe.service"
```

Verify the remote service:

```bash
ssh <vm>.exe.xyz 'systemctl is-enabled moqx-quicprobe.service; systemctl is-active moqx-quicprobe.service; ss -lunp | grep <quic-port>'
ssh <vm>.exe.xyz '/opt/moqx-bench/quicprobe/current/bin/quicprobe client --addr 127.0.0.1:<quic-port> --ca /opt/moqx-bench/quicprobe/tls/ca.pem --servername <server-name> --initial-packet-size 1200 --bidi-echo smoke --timeout 5s'
ssh <vm>.exe.xyz 'TS_IP=$(tailscale ip -4 | head -1); /opt/moqx-bench/quicprobe/current/bin/quicprobe client --addr ${TS_IP}:<quic-port> --ca /opt/moqx-bench/quicprobe/tls/ca.pem --servername <server-name> --initial-packet-size 1200 --bidi-echo tailnet-self --timeout 5s'
ssh <vm>.exe.xyz 'sudo tail -n 3 /var/lib/moqx-quicprobe/quicprobe-evidence.jsonl'
```

For local-to-remote client verification:

```bash
scp <vm>.exe.xyz:/opt/moqx-bench/quicprobe/tls/ca.pem /private/tmp/quicprobe-ca.pem
/path/to/quicprobe client --addr <tailnet-ip>:<quic-port> --ca /private/tmp/quicprobe-ca.pem --servername <server-name> --initial-packet-size 1200 --bidi-echo smoke --timeout 10s
/path/to/quicprobe client --addr <tailnet-ip>:<quic-port> --ca /private/tmp/quicprobe-ca.pem --servername <server-name> --initial-packet-size 1200 --json --workload datagram_pressure --datagram-size 64 --datagram-count 5 --timeout 10s
```

If local-to-remote quicprobe times out while `iperf3 --udp` works over
Tailscale, first verify both sides are using `--initial-packet-size 1200` and
that the local client is a build with that flag. Then check route MTU, local
Tailscale status, service logs, and server run evidence before blaming firewall
rules.
