# Giulia Core - Multi-Stage Docker Build
# Image: giulia/core:latest
#
# HTTP API daemon - simple, reliable, no EPMD drama.

# ============================================================================
# Stage 1: Build Environment
# ============================================================================
FROM elixir:1.19-otp-27-alpine AS builder

RUN apk add --no-cache \
    build-base \
    git \
    npm \
    sqlite-dev

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config config
RUN mix deps.compile

COPY lib lib
COPY priv priv
COPY rel rel

RUN mix compile
RUN mix release giulia

# ============================================================================
# Stage 2: Runtime Environment
# ============================================================================
FROM elixir:1.19-otp-27-alpine AS runtime

RUN apk add --no-cache \
    sqlite-libs \
    ca-certificates \
    git

# Install hex and rebar for run_mix tool on user projects
# Must be done BEFORE switching to non-root user
ENV MIX_HOME=/opt/mix \
    HEX_HOME=/opt/hex

RUN mkdir -p /opt/mix /opt/hex && \
    mix local.hex --force && \
    mix local.rebar --force && \
    chmod -R 755 /opt/mix /opt/hex

RUN addgroup -g 1000 giulia && \
    adduser -u 1000 -G giulia -s /bin/sh -D giulia

RUN mkdir -p /app /data /projects && \
    chown -R giulia:giulia /app /data /projects

WORKDIR /app

COPY --from=builder --chown=giulia:giulia /app/_build/prod/rel/giulia ./

USER giulia

# Simple environment - just HTTP, no Erlang distribution complexity
# MIX_HOME/HEX_HOME needed for run_mix tool on user projects
# GIULIA_IN_CONTAINER tells PathMapper to use host.docker.internal
ENV HOME=/app \
    GIULIA_HOME=/data \
    GIULIA_PORT=4000 \
    MIX_HOME=/opt/mix \
    HEX_HOME=/opt/hex \
    GIULIA_IN_CONTAINER=true

# HTTP API port
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget -q --spider http://localhost:4000/health || exit 1

VOLUME ["/data", "/projects"]

ENTRYPOINT ["/app/bin/giulia"]
CMD ["start"]
