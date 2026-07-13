# syntax=docker/dockerfile:1.7

ARG RUST_IMAGE="rust:1.94.0-bookworm@sha256:365468470075493dc4583f47387001854321c5a8583ea9604b297e67f01c5a4f"
ARG RUNTIME_IMAGE="debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df"

FROM ${RUST_IMAGE} AS builder

ARG MOQ_RS_REPOSITORY="https://github.com/cloudflare/moq-rs.git"
ARG MOQ_RS_REF

RUN test -n "${MOQ_RS_REF}"
RUN git clone --filter=blob:none "${MOQ_RS_REPOSITORY}" /src && \
    git -C /src checkout --detach "${MOQ_RS_REF}"

WORKDIR /src

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --locked --release --package moq-relay-ietf --bin moq-relay-ietf && \
    cp /src/target/release/moq-relay-ietf /usr/local/bin/moq-relay-ietf

FROM ${RUNTIME_IMAGE}

ARG MOQ_RS_REF

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl libssl3 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/moq-relay-ietf /usr/local/bin/moq-relay-ietf

LABEL org.opencontainers.image.source="https://github.com/cloudflare/moq-rs"
LABEL org.opencontainers.image.revision="${MOQ_RS_REF}"

EXPOSE 443/tcp 443/udp

ENTRYPOINT ["moq-relay-ietf"]
