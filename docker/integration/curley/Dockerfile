# syntax=docker/dockerfile:1.7

FROM moqx-curley-moq-lite-05 AS curley

FROM hexpm/elixir:1.19.0-erlang-27.3-debian-bookworm-20260610-slim@sha256:9a4c087df2ac9c1712a8c127113a549c9dab90e1960d0d442601df3bf1ee3826

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      git \
      libssl-dev \
      pkg-config && \
    rm -rf /var/lib/apt/lists/*

COPY --from=curley /usr/local/bin/moq /usr/local/bin/moq
COPY --from=curley /usr/local/bin/moqx-curley-timestamp-probe \
    /usr/local/bin/moqx-curley-timestamp-probe

ENV MIX_ENV=test
WORKDIR /workspace

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.cache/rebar3 \
    mix deps.get
RUN --mount=type=cache,target=/root/.cache/rebar3 \
    mix deps.compile

COPY . .

CMD ["mix", "test", "test/integration/curley_moq_lite_05_relay_test.exs", "--include", "integration", "--include", "curley_moq_lite_05"]
