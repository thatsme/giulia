# Giulia Core - Development Docker Image
# Image: giulia/core:latest
#
# No OTP release — runs directly with `mix run --no-halt`.
# Releases are for production. Giulia is a development tool.

FROM elixir:1.19-otp-27-alpine

RUN apk add --no-cache \
    build-base \
    git \
    npm \
    sqlite-dev \
    sqlite-libs \
    ca-certificates

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
    GIULIA_PORT=4000

# Copy project files
COPY mix.exs mix.lock ./
RUN mix deps.get

COPY config config
RUN mix deps.compile

COPY lib lib
COPY priv priv
RUN mix compile

# Create data directories
RUN mkdir -p /data /projects

# HTTP API port
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget -q --spider http://localhost:4000/health || exit 1

VOLUME ["/data", "/projects"]

CMD ["mix", "run", "--no-halt"]
