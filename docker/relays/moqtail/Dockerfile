# syntax=docker/dockerfile:1.7

ARG RUST_IMAGE="rust:1.94.0-bookworm@sha256:365468470075493dc4583f47387001854321c5a8583ea9604b297e67f01c5a4f"
ARG RUNTIME_IMAGE="debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df"

FROM ${RUST_IMAGE} AS builder

ARG MOQTAIL_REPOSITORY="https://github.com/moqtail/moqtail.git"
ARG MOQTAIL_REF

RUN test -n "${MOQTAIL_REF}"
RUN git clone --filter=blob:none "${MOQTAIL_REPOSITORY}" /src && \
    git -C /src checkout --detach "${MOQTAIL_REF}"

WORKDIR /src

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --locked --release --package relay --package client && \
    cp /src/target/release/relay /usr/local/bin/moqtail-relay && \
    cp /src/target/release/client /usr/local/bin/moqtail-client

FROM ${RUNTIME_IMAGE}

ARG MOQTAIL_REF

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/moqtail-relay /usr/local/bin/moqtail-relay
COPY --from=builder /usr/local/bin/moqtail-client /usr/local/bin/moqtail-client

LABEL org.opencontainers.image.source="https://github.com/moqtail/moqtail"
LABEL org.opencontainers.image.revision="${MOQTAIL_REF}"

EXPOSE 4433/udp
