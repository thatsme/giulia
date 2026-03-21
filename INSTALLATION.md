# Installation Guide

## Prerequisites

- **Docker Desktop** with Compose v2 plugin (`docker compose`, NOT `docker-compose` v1 standalone). The v1 binary fails on Windows with "driver not connecting" errors.
- **Git**
- **8 GB+ RAM** recommended. The worker container is limited to 4 GB, the monitor to 2 GB.

## Clone and Build

```bash
git clone https://github.com/thatsme/giulia.git
cd giulia

# Build the Docker image
docker compose build

# Full rebuild (no cache) -- use when dependencies change or builds are broken
docker compose build --no-cache
```

## ArcadeDB Setup

ArcadeDB runs as an **external standalone container**, not managed by Giulia's compose file. Start it separately:

```bash
docker run -d \
  --name arcadedb \
  -p 2480:2480 \
  -e "JAVA_OPTS=-Darcadedb.server.rootPassword=playwithdata -Xmx512m" \
  -v arcadedb_data:/home/arcadedb/databases \
  arcadedata/arcadedb:latest
```

The worker container connects to ArcadeDB via `ARCADEDB_URL=http://host.docker.internal:2480` (the default). This uses Docker Desktop's host gateway to reach the ArcadeDB container from inside the Giulia network.

Verify ArcadeDB is running:

```bash
curl http://localhost:2480/api/v1/server
```

## Start the Daemon

```bash
# Start both worker (port 4000) and monitor (port 4001)
docker compose up -d

# Start worker only (standalone mode, no monitor)
docker compose up -d giulia-worker

# Check logs
docker compose logs -f

# Stop all containers
docker compose down
```

## Verify

```bash
# Health check
curl http://localhost:4000/health

# Worker logs
docker compose logs -f giulia-worker

# Monitor logs (if running)
docker compose logs -f giulia-monitor
```

## Environment Variables

The following environment variables are defined in the `x-common-env` anchor in `docker-compose.yml` and apply to both containers unless overridden:

| Variable | Default | Description |
|---|---|---|
| `GIULIA_HOME` | `/data` | Data directory inside the container |
| `GIULIA_IN_CONTAINER` | `true` | Signals that Giulia is running inside Docker |
| `GIULIA_COOKIE` | `giulia_dev` | Erlang distribution cookie for node authentication. **Change this before connecting to non-trivial nodes or exposing over a network.** |
| `GIULIA_HOST_PROJECTS_PATH` | *(required)* | Host-side path prefix for path translation. Example: `D:/Development/GitHub` (Windows) or `/home/user/projects` (Linux). Must match the host side of your Docker volume mount. |
| `GIULIA_PATH_MAPPING` | (empty) | Custom path mapping overrides |
| `GIULIA_PORT` | `4000` (worker), `4001` (monitor) | HTTP API port |
| `GIULIA_ROLE` | `worker` or `monitor` | Container role. Determines which OTP children start. |
| `ARCADEDB_URL` | `http://host.docker.internal:2480` | ArcadeDB REST API endpoint (worker only) |
| `GIULIA_CONNECT_NODE` | `worker@giulia-worker` | Target node for auto-connect (monitor only) |
| `GIULIA_WORKER_NODE_NAME` | `worker` | Worker Erlang node short name |
| `GIULIA_MONITOR_NODE_NAME` | `monitor` | Monitor Erlang node short name |
| `ANTHROPIC_API_KEY` | (empty) | Anthropic Claude API key |
| `GROQ_API_KEY` | (empty) | Groq API key |
| `GEMINI_API_KEY` | (empty) | Gemini API key |
| `LM_STUDIO_URL` | `http://host.docker.internal:1234/v1/chat/completions` | LM Studio chat completions endpoint. Use `host.docker.internal` (Docker Desktop) or your machine's LAN IP. |
| `XLA_TARGET` | `cpu` | EXLA compilation target |
| `MIX_ENV` | `dev` | Elixir environment |

## Node Configuration (Distributed Erlang)

The worker and monitor form a two-node Erlang cluster. Both nodes must share the same cookie.

### Ports

| Service | HTTP | EPMD (host) | Distribution Range |
|---|---|---|---|
| Worker | 4000 | 4369 | 9100-9105 |
| Monitor | 4001 | 4370 (mapped from 4369) | 9110-9115 |

The monitor maps EPMD to host port 4370 to avoid collision with the worker's 4369 mapping. Inside the Docker network, both containers use port 4369 in their own namespace -- no conflict.

### Node Names

- Worker: `worker@giulia-worker` (override with `GIULIA_WORKER_NODE_NAME`)
- Monitor: `monitor@giulia-monitor` (override with `GIULIA_MONITOR_NODE_NAME`)

## Connecting External BEAM Apps

You can connect Giulia to any running BEAM application for runtime introspection.

1. Start your app with distributed Erlang enabled and the same cookie:

```bash
iex --name myapp@192.168.1.50 --cookie giulia_dev -S mix
```

2. Mount your app's source code in Giulia's Docker volume (via the `GIULIA_PROJECTS_PATH` env var or docker-compose volumes).

3. Connect Giulia to your app:

```bash
curl -X POST http://localhost:4000/api/runtime/connect \
  -H "Content-Type: application/json" \
  -d '{"node":"myapp@192.168.1.50","cookie":"giulia_dev"}'
```

4. Query with fused static + runtime data:

```bash
# Hot spots: PID -> Module -> Property Graph fusion
curl "http://localhost:4000/api/runtime/hot_spots?path=D:/Development/GitHub/MyApp&node=myapp@192.168.1.50"
```

The remote app must be reachable from inside the Docker container. For apps on the host machine, use `host.docker.internal` as the hostname.

## Building the Thin Client

The thin client is a standalone binary that sends HTTP requests to the daemon.

### Development (requires Elixir runtime)

```bash
mix escript.build
# Output: ./giulia
```

### Production (standalone via Burrito)

```bash
MIX_ENV=prod mix release giulia_client
# Output: burrito_out/giulia_windows.exe
#         burrito_out/giulia_linux
#         burrito_out/giulia_macos
#         burrito_out/giulia_macos_arm
```

## Running Without Docker (Development Only)

If you have Elixir installed locally (note: EXLA will not compile on Windows):

```bash
iex -S mix
```

In another terminal:

```bash
mix escript.build && ./giulia "hello"
```

## Full Rebuild

When things go wrong (corrupted state, dependency issues, stale images):

```bash
# Stop everything
docker compose down

# Rebuild from scratch
docker compose build --no-cache

# Clear corrupted CubDB caches (run for each affected project)
rm -rf /path/to/project/.giulia/cache/cubdb_worker/*

# Restart
docker compose up -d
```

## Test Environment

Tests run inside Docker using a dedicated compose file with its own ArcadeDB instance and fresh volumes:

```bash
# Run all tests
docker compose -f docker-compose.test.yml run --rm giulia-test

# Run a single test file
docker compose -f docker-compose.test.yml run --rm giulia-test test/giulia/inference/state_test.exs

# Clean up test containers and volumes
docker compose -f docker-compose.test.yml down -v
```

See [TESTING.md](TESTING.md) for the full testing guide.

## Troubleshooting

### Port already in use

If port 4000 is already bound:

```bash
# Find what is using the port
# Linux/macOS:
lsof -i :4000
# Windows:
netstat -ano | findstr :4000

# Stop the conflicting process, or change GIULIA_PORT in docker-compose.yml
```

### EXLA will not compile on Windows

EXLA requires a C compiler toolchain that is not available on Windows. Always compile inside Docker. Tests must also run inside Docker for this reason.

### CubDB corruption

CubDB files can become corrupted across container restarts. Symptoms include startup crashes or missing index data. To fix:

```bash
# Remove the corrupted cache for the affected project
rm -rf /path/to/project/.giulia/cache/cubdb_worker/*

# Restart -- Giulia will do a cold scan and rebuild the cache
docker compose restart giulia-worker
```

ArcadeDB L2 storage mitigates this by preserving historical data independently of CubDB.

### LM Studio not responding

If local LLM calls fail:

1. Verify LM Studio is running and a model is loaded.
2. Check the configured URL: `curl http://localhost:1234/v1/models`
3. Ensure the `LM_STUDIO_URL` env var in docker-compose.yml points to your host IP (not `localhost`, which resolves to the container itself). Use `host.docker.internal` or your LAN IP.

### Monitor cannot connect to worker

The monitor waits for the worker health check to pass before starting. If it keeps restarting:

1. Check worker health: `curl http://localhost:4000/health`
2. Verify both containers share the same cookie (`GIULIA_COOKIE`).
3. Check that EPMD is reachable: `docker compose exec giulia-monitor epmd -names`
