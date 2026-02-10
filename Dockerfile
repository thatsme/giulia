# Giulia Core - Development Docker Image
# Image: giulia/core:latest
#
# No OTP release — runs directly with `mix run --no-halt`.
# Releases are for production. Giulia is a development tool.
#
# Uses Debian-slim (not Alpine) because EXLA requires glibc.

FROM elixir:1.19-otp-27-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    ca-certificates \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

# Isolated build paths — never touch the host's Windows _build
ENV MIX_ENV=dev \
    MIX_BUILD_PATH=/tmp/giulia_build \
    MIX_DEPS_PATH=/tmp/giulia_deps \
    MIX_HOME=/root/.mix \
    HEX_HOME=/root/.hex \
    GIULIA_IN_CONTAINER=true \
    GIULIA_HOME=/data \
    GIULIA_PORT=4000 \
    XLA_TARGET=cpu

# Copy project files
COPY mix.exs mix.lock ./
RUN mix deps.get

COPY config config
RUN mix deps.compile

COPY lib lib
COPY priv priv
COPY test test
RUN mix compile
RUN mix test --trace

# Model downloads on first startup (needs CUDA runtime from nvidia-docker)
# Cached in /root/.cache via giulia_models volume

# Create data directories
RUN mkdir -p /data /projects

# HTTP API port
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -sf http://localhost:4000/health || exit 1

VOLUME ["/data", "/projects"]

CMD ["mix", "run", "--no-halt"]
