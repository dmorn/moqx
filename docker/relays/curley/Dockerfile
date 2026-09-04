# syntax=docker/dockerfile:1.7

ARG RUST_IMAGE="rust:1.94.0-bookworm@sha256:365468470075493dc4583f47387001854321c5a8583ea9604b297e67f01c5a4f"
ARG RUNTIME_IMAGE="debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df"

FROM ${RUST_IMAGE} AS builder

ARG MOQ_REPOSITORY="https://github.com/moq-dev/moq.git"
ARG MOQ_REF

RUN test -n "${MOQ_REF}"
RUN git clone --filter=blob:none "${MOQ_REPOSITORY}" /src && \
    git -C /src checkout --detach "${MOQ_REF}"

COPY docker/integration/curley/timestamp_probe.rs \
    /src/rs/moq-native/examples/moqx_curley_timestamp_probe.rs

WORKDIR /src

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --locked --release \
      -p moq-relay \
      -p moq-cli \
      -p moq-native --example moqx_curley_timestamp_probe && \
    cp /src/target/release/moq-relay /usr/local/bin/moq-relay && \
    cp /src/target/release/moq /usr/local/bin/moq && \
    cp /src/target/release/examples/moqx_curley_timestamp_probe \
      /usr/local/bin/moqx-curley-timestamp-probe

FROM ${RUNTIME_IMAGE}

ARG MOQ_REF

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/moq-relay /usr/local/bin/moq-relay
COPY --from=builder /usr/local/bin/moq /usr/local/bin/moq
COPY --from=builder /usr/local/bin/moqx-curley-timestamp-probe \
    /usr/local/bin/moqx-curley-timestamp-probe

LABEL org.opencontainers.image.source="https://github.com/moq-dev/moq"
LABEL org.opencontainers.image.revision="${MOQ_REF}"

EXPOSE 443/udp
