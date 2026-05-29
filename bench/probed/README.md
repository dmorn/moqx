# Probed

`bench/probed` is the future remote control-plane process for transport
benchmarks.

The daemon is intentionally thin:

- it will prepare and run benchmark commands on disposable lab nodes;
- it will collect run artifacts, logs, and telemetry output;
- it will expose a small HTTP API for the local operator/controller;
- it must not own benchmark semantics that belong in `bench/moqxprobe`;
- it must not depend on `moqx`, `moqxprobe`, or quicer just to run
  the control plane;
- it may depend on `bench/ledger` for shared JSONL/metadata specs.

For now this project is a scaffold so packaging and deployment experiments can
target a daemon-shaped Elixir release without coupling the control plane design
to the current CLI internals.
