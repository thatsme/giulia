# CLAUDE.md - Project Context for AI Assistants

## What is Giulia?

Giulia is a high-performance, local-first AI development agent built in Elixir. She is designed to eventually replace Claude Code by leveraging the BEAM's strengths: fault-tolerance, concurrency, and stateful long-running processes.

**Key Differentiator**: Giulia runs as a **persistent background daemon** with **multi-project awareness**. You don't restart the agent every time you change folders.

## Core Philosophy

1. **OTP First** - State lives in GenServers and ETS, not in chat history
2. **Daemon-Client** - System-wide binary talks to persistent background daemon
3. **No Shell Confusion** - All file operations use native Elixir `File` module or `Path` structs
4. **Native AST** - Use Sourceror (pure Elixir) for code analysis, not tree-sitter NIFs
5. **Provider Agnostic** - Anthropic API at work, Ollama (local Qwen 32B) at home
6. **Structured Intelligence** - All tool calls use Ecto schemas for validation
7. **Sandboxed** - Giulia can ONLY access files under GIULIA.md (the constitution)

## Project Structure

```
lib/
├── giulia.ex                    # Main API (legacy direct interface)
├── giulia/
│   ├── application.ex           # OTP Supervision Tree
│   ├── client.ex                # HTTP thin client (escript entry point)
│   ├── cli.ex                   # Legacy RPC client (deprecated)
│   ├── daemon.ex                # Persistent background service
│   ├── provider.ex              # LLM Provider behavior
│   ├── structured_output.ex     # JSON validation + extraction for small models
│   │
│   ├── core/
│   │   ├── context_manager.ex   # Routes PWD to correct ProjectContext
│   │   ├── project_context.ex   # Per-project GenServer (AST, history, constitution)
│   │   ├── path_sandbox.ex      # Security: prevents reading outside project
│   │   └── path_mapper.ex       # Host/container path translation
│   │
│   ├── daemon/
│   │   ├── endpoint.ex          # Bandit HTTP API — core routes + forwards (Build 94)
│   │   ├── helpers.ex           # Shared helpers (send_json, resolve_project_path, etc.)
│   │   ├── skill_router.ex      # `use SkillRouter` macro: Plug.Router + @skill accumulator
│   │   └── routers/
│   │       ├── approval.ex      # 2 routes: POST/GET /api/approval/:id
│   │       ├── transaction.ex   # 3 routes: enable, staged, rollback
│   │       ├── index.ex         # 6 routes: modules, functions, module_details, summary, status, scan
│   │       ├── search.ex        # 3 routes: search, semantic, semantic/status
│   │       ├── intelligence.ex  # 4 routes: briefing, preflight, architect, validate
│   │       ├── runtime.ex       # 8 routes: pulse, top_processes, hot_spots, trace, history, trend, alerts, connect
│   │       ├── knowledge.ex     # 23 routes: all /api/knowledge/* endpoints
│   │       ├── monitor.ex       # 3 routes: dashboard, SSE stream, history (Build 95)
│   │       └── discovery.ex     # 3 routes: skills, categories, search (Build 98)
│   │
│   ├── monitor/
│   │   ├── store.ex             # Rolling buffer GenServer + SSE pub/sub (Build 95)
│   │   └── telemetry.ex         # :telemetry handler attachment (Build 95)
│   │
│   ├── inference/
│   │   ├── orchestrator.ex      # OODA loop (THINK-VALIDATE-REFLECT-EXECUTE)
│   │   ├── pool.ex              # Provider connection pooling
│   │   └── supervisor.ex        # Inference supervisor hierarchy
│   │
│   ├── provider/
│   │   ├── anthropic.ex         # Claude API (cloud, high-intensity)
│   │   ├── ollama.ex            # Ollama API (local, heavy)
│   │   ├── lm_studio.ex         # LM Studio (local, fast micro-tasks)
│   │   └── router.ex            # Task classification (low vs high intensity)
│   │
│   ├── context/
│   │   ├── store.ex             # ETS-backed project state
│   │   ├── indexer.ex           # Background AST scanner (Task.async_stream)
│   │   └── builder.ex           # Dynamic system prompt construction
│   │
│   ├── persistence/
│   │   ├── store.ex             # CubDB lifecycle (lazy open per project)
│   │   ├── writer.ex            # Async write-behind (100ms debounce batching)
│   │   ├── loader.ex            # Startup recovery (CubDB → ETS warm start)
│   │   └── merkle.ex            # Merkle tree (build/update/verify/diff)
│   │
│   ├── prompt/
│   │   └── builder.ex           # Constitution + context building for LLM
│   │
│   ├── ast/
│   │   └── processor.ex         # Sourceror: parse, analyze, patch, slice
│   │
│   ├── agent/
│   │   ├── orchestrator.ex      # Legacy orchestrator (see inference/)
│   │   └── router.ex            # Task routing (local vs cloud)
│   │
│   └── tools/
│       ├── registry.ex          # Auto-discovers tools on boot
│       ├── read_file.ex         # Sandboxed file reading
│       ├── write_file.ex        # Sandboxed file writing
│       ├── edit_file.ex         # Edit file with AST patching
│       ├── run_mix.ex           # Run mix commands
│       ├── search_code.ex       # Code search
│       ├── list_files.ex        # List directory contents
│       ├── get_context.ex       # Get surrounding code context
│       ├── get_function.ex      # Extract function by name/arity
│       ├── get_module_info.ex   # Get module metadata
│       ├── think.ex             # Model thinking/reasoning
│       └── respond.ex           # Final response to user
```

## Key Design Decisions

### Why Daemon-Client Architecture?

```
Terminal A: ~/alpha    Terminal B: ~/beta
    │                        │
    ▼                        ▼
┌─────────────────────────────────────────┐
│         GIULIA DAEMON (BEAM)            │
│  ProjectContext(alpha)  ProjectContext(beta)
│  - AST cached           - AST cached
│  - History in SQLite    - History in SQLite
│  - Constitution loaded  - Constitution loaded
└─────────────────────────────────────────┘
```

- **Warm LLM**: Local models take time to load. Keep them warm.
- **Hot AST Cache**: Don't re-index 500 files every terminal session.
- **Multi-Project**: Isolated contexts, instant switching.
- **System-Wide**: Type `giulia` anywhere.

### Why GIULIA.md (The Constitution)?

Claude Code guesses your project's intent. Giulia **reads her constitution**.

```markdown
## Taboos (Never Do This)
- Never use umbrella projects
- Never add dependencies without approval

## Preferred Patterns
- Use context modules for business logic
```

If the model violates the constitution, **Giulia intercepts and rewrites** before showing you.

### Why Path Sandbox?

Giulia can ONLY read/write files **under the folder where GIULIA.md lives**. Not `~/.ssh/config`. Not `/etc/passwd`. The model can't escape.

```elixir
# The Senior Way (not checking for ".." strings)
PathSandbox.validate(sandbox, path)
# Expands to absolute path, verifies containment
```

### Why Sourceror instead of Tree-sitter?
- Pure Elixir, no C compiler needed
- Can parse AND write back code with formatting preserved
- Better for "father-killing" (Giulia improving her own code)
- Tree-sitter can be added later as a sidecar for multi-language support

### Why Two Providers (Cloud + Local)?
- **Cloud (Anthropic)**: Heavy lifting - architecture, debugging, multi-file refactoring
- **Local (LM Studio/Qwen 3B)**: Micro-tasks - docstrings, formatting, variable names
- Router classifies tasks and picks the right brain
- Don't use a sledgehammer (Claude) to hang a picture frame

## Build Counter (MANDATORY)

Every code modification MUST increment `@build` in `mix.exs` before building.
This is how we track which version is running on client vs server.

```elixir
# In mix.exs — increment this on EVERY change
@build 34
```

## Using Giulia's API for Code Analysis (PREFERRED)

When the Giulia daemon is running (Docker or local), **always prefer querying the live API** over raw file searches for code status and analysis. The daemon has pre-indexed AST data, a Knowledge Graph, and function metadata — use it.

**Index API** (ETS-backed, instant):
```bash
# All modules in the project
curl http://localhost:4000/api/index/modules

# Functions in a specific module (with arities, line numbers, types)
curl http://localhost:4000/api/index/functions?module=Giulia.Tools.Registry

# Full project summary (modules, functions, types, specs, structs, callbacks)
curl http://localhost:4000/api/index/summary

# Indexer status (idle/scanning, file count, last scan time)
curl http://localhost:4000/api/index/status
```

**Knowledge Graph API** (dependency topology):
```bash
# Graph statistics (vertices, edges, components, top hubs)
curl http://localhost:4000/api/knowledge/stats

# Who depends on module X (downstream blast radius)
curl http://localhost:4000/api/knowledge/dependents?module=Giulia.Tools.Registry

# What module X depends on (upstream dependencies)
curl http://localhost:4000/api/knowledge/dependencies?module=Giulia.Tools.Registry

# Hub score (in-degree, out-degree — high = dangerous to modify)
curl http://localhost:4000/api/knowledge/centrality?module=Giulia.Tools.Registry

# Full impact map (upstream + downstream at depth N)
curl "http://localhost:4000/api/knowledge/impact?module=Giulia.Tools.Registry&depth=2"

# Shortest path between two modules
curl "http://localhost:4000/api/knowledge/path?from=Giulia.Client&to=Giulia.Tools.Registry"
```

**When to use what:**
- **Verify interface contracts** → `/api/index/functions?module=X` (shows all arities)
- **Assess blast radius before refactoring** → `/api/knowledge/dependents?module=X`
- **Check if module is a hub** → `/api/knowledge/centrality?module=X`
- **Understand project shape** → `/api/index/summary`
- **Find dependency chains** → `/api/knowledge/path?from=A&to=B`

**Rule**: If Giulia's daemon is up, query it first. Don't grep for what ETS already knows.

## Development Commands

```bash
# Compile
mix compile

# Run interactive
iex -S mix
```

## Testing (CRITICAL — read TESTING.md for full details)

Tests MUST run inside Docker from the live-mounted volume. Never run from `/app`.

```bash
# Run ALL tests
docker compose exec giulia-daemon bash -c "cd /projects/Giulia && MIX_ENV=test mix test"

# Run single file
docker compose exec giulia-daemon bash -c "cd /projects/Giulia && MIX_ENV=test mix test test/giulia/foo/bar_test.exs"

# Run specific test by line
docker compose exec giulia-daemon bash -c "cd /projects/Giulia && MIX_ENV=test mix test test/giulia/foo/bar_test.exs:42"
```

**Why:** EXLA doesn't compile on Windows. `MIX_ENV=test` skips Bandit (port 4000 conflict).
`/projects/Giulia` is the live host mount; `/app` is a stale image copy.

## Building the Light Client (HTTP-based thin client)

```bash
# Build escript (development, requires Elixir runtime)
mix escript.build
# Output: ./giulia (Unix) or giulia (Windows batch)

# Build native binary via Burrito (production, standalone)
MIX_ENV=prod mix release giulia_client

# Output locations (Burrito):
# burrito_out/giulia_windows.exe
# burrito_out/giulia_linux
# burrito_out/giulia_macos
# burrito_out/giulia_macos_arm
```

## Building the Docker Daemon

**IMPORTANT**: Use `docker compose` (v2 plugin), NOT `docker-compose` (v1 standalone).
The v1 binary fails on Windows with "driver not connecting" errors.

```bash
# Build Docker image
docker compose build
# Or: docker build -t giulia/core:latest .

# Start daemon (background)
docker compose up -d

# Check logs
docker compose logs -f

# Stop daemon
docker compose down

# Full rebuild (no cache)
docker compose build --no-cache
```

## Running Without Docker (development)

```bash
# Start daemon in foreground
iex -S mix

# In another terminal, use the client
mix escript.build && ./giulia "hello"
```

## Storage Locations

- **Global**: `~/.config/giulia/` - Daemon logs, PID file, global cache
- **Per-Project**: `.giulia/` - Chat history (SQLite), local cache
- **Constitution**: `GIULIA.md` - Project rules, tech stack, taboos

## Configuration Rules (CRITICAL)

**NO HARDCODED URLS OR PATHS IN CODE**

All external URLs (LM Studio, Anthropic, etc.) MUST be resolved through:
1. `System.get_env("ENV_VAR_NAME")` - First priority
2. `Giulia.Core.PathMapper` functions - Docker-aware defaults
3. `Application.get_env(:giulia, :key)` - Application config

**Example - WRONG:**
```elixir
# DON'T DO THIS
url = "http://127.0.0.1:1234/v1/models"
```

**Example - CORRECT:**
```elixir
# DO THIS - uses env var or Docker-aware default
url = Giulia.Core.PathMapper.lm_studio_models_url()
```

**PathMapper Functions:**
- `lm_studio_url/0` - Chat completions endpoint
- `lm_studio_models_url/0` - Models list endpoint
- `lm_studio_base_url/0` - Base URL without path
- `in_container?/0` - Detect if running in Docker

## Environment Variables

**All Giulia-specific env vars use the `GIULIA_` prefix for consistency.**

- `ANTHROPIC_API_KEY` - Required for Anthropic provider (standard Anthropic naming)
- `GIULIA_LM_STUDIO_URL` - LM Studio base URL (e.g., `http://192.168.1.52:1234`)
- `GIULIA_LM_STUDIO_MODEL` - LM Studio model name (e.g., `qwen/qwen2.5-coder-14b`)
- `GIULIA_IN_CONTAINER` - Set to "true" when running in Docker (auto-detected via /.dockerenv)
- `GIULIA_HOST_PROJECTS_PATH` - Host path prefix for path mapping (e.g., `C:/Development/GitHub`)
- `GIULIA_HOME` - Data directory inside container (default: /data)
- `GIULIA_PORT` - HTTP API port (default: 4000)
- `GIULIA_DAEMON_MODE` - Set to "true" to force daemon mode
- `GIULIA_CLIENT_MODE` - Set to "true" to force client mode
- `GIULIA_COOKIE` - Erlang distribution cookie for remote node auth (default: `giulia_dev`)
- `GIULIA_ROLE` - Container role: `worker`, `monitor`, or `standalone` (default: `standalone`)
- `GIULIA_CONNECT_NODE` - Target node for auto-connect (e.g., `worker@giulia-worker`). Monitor mode only.
- `GIULIA_WORKER_NODE_NAME` - Worker Erlang node name (default: `worker@giulia-worker`)
- `GIULIA_MONITOR_NODE_NAME` - Monitor Erlang node name (default: `monitor@giulia-monitor`)

## Docker Run Command (EXACT)

```bash
docker run -d \
  --name giulia-daemon \
  -p 4000:4000 \
  -p 4369:4369 \
  -p 9100-9105:9100-9105 \
  -e GIULIA_LM_STUDIO_URL=http://192.168.1.52:1234 \
  -e GIULIA_HOST_PROJECTS_PATH="C:/Development/GitHub" \
  -e GIULIA_COOKIE=giulia_dev \
  -v "C:/Development/GitHub:/projects" \
  giulia/core:latest
```

**Critical**: `GIULIA_HOST_PROJECTS_PATH` must match the host side of the `-v` mount.
The daemon uses this to translate Windows paths (from client) to container paths.

**Ports:**
- `4000` - HTTP API
- `4369` - EPMD (Erlang Port Mapper Daemon)
- `9100-9105` - Erlang distribution port range (for remote node connections)

## Debugging

```bash
# Check if LM Studio is responding
curl http://localhost:1234/v1/models

# Watch daemon logs (Docker)
docker-compose logs -f

# Run with verbose logging (development)
iex -S mix
# In iex: Logger.configure(level: :debug)
```

**Common issues:**
- `:max_iterations_exceeded` - Model keeps looping without calling `respond`. Try simpler task or check LM Studio model.
- `:no_provider_available` - Neither LM Studio nor Anthropic API available. Check LM Studio is running.
- Search returns nothing - Dependencies (`deps/`) are not searched, only project source files.

## Runtime Introspection (Distributed Erlang)

Giulia can inspect any running BEAM node — either itself or a remote application. The Docker daemon starts with distributed Erlang enabled (`--name giulia@0.0.0.0 --cookie giulia_dev`).

### Mode 1: Self-Introspection (default)

Giulia inspects its own BEAM VM. No configuration needed.

```bash
# BEAM health (memory, processes, schedulers, ETS)
curl http://localhost:4000/api/runtime/pulse

# Top 10 processes by CPU
curl http://localhost:4000/api/runtime/top_processes?metric=reductions

# Hot modules fused with Knowledge Graph
curl "http://localhost:4000/api/runtime/hot_spots?path=C:/Development/GitHub/Giulia"
```

### Mode 2: Remote Node Introspection

Connect to an external BEAM app to harvest its runtime data while using Giulia's static analysis on its source code.

**Step 1: Start your app with distribution enabled and the same cookie:**
```bash
iex --name myapp@192.168.1.50 --cookie giulia_dev -S mix
```

**Step 2: Mount your app's source code in Giulia's Docker volume** (via `GIULIA_PROJECTS_PATH` or docker-compose volumes).

**Step 3: Connect Giulia to your app:**
```bash
curl -X POST http://localhost:4000/api/runtime/connect \
  -H "Content-Type: application/json" \
  -d '{"node":"myapp@192.168.1.50","cookie":"giulia_dev"}'
```

**Step 4: Query with both static + runtime data:**
```bash
# Scan your app's source code (static analysis)
curl -X POST http://localhost:4000/api/index/scan \
  -H "Content-Type: application/json" \
  -d '{"path":"C:/Development/GitHub/MyApp"}'

# Hot spots: PID → Module → Knowledge Graph fusion (live + static)
curl "http://localhost:4000/api/runtime/hot_spots?path=C:/Development/GitHub/MyApp&node=myapp@192.168.1.50"

# Architect brief with runtime section included
curl "http://localhost:4000/api/brief/architect?path=C:/Development/GitHub/MyApp"
```

**Cookie authentication:** Both nodes MUST share the same Erlang cookie. Set `GIULIA_COOKIE` env var in docker-compose.yml to match your app's cookie. Default is `giulia_dev`.

**Network:** The remote app must be reachable from inside the Docker container. For apps on the host machine, use the Docker host IP (e.g., `host.docker.internal` on Docker Desktop).

## Current Status

- HTTP daemon-client architecture implemented (Bandit on :4000)
- Multi-project awareness via ContextManager
- Path sandbox security in place
- OODA inference loop (THINK-VALIDATE-REFLECT-EXECUTE) implemented
- 12+ tools registered (read, write, edit, search, etc.)
- AST indexing with Sourceror (parallel scanning)
- LM Studio provider working, Anthropic/Ollama need verification
- Docker deployment ready (Dockerfile + docker-compose.yml)
- HTTP thin client (`client.ex`) is the active entry point
- **Build 91**: Architect Brief — single-call session briefing (`/api/brief/architect`)
- **Build 92**: Runtime Proprioception — BEAM introspection, Collector, 8 runtime endpoints, Distributed Erlang enabled
- **Build 93**: Plan Validation Gate — graph-aware plan validation (`/api/plan/validate`)
- **Build 94**: The Great Decoupling — Endpoint split into 7 domain sub-routers (1,331→266 lines, 80% reduction), `@skill` decorator pattern with `__skills__/0` introspection, `SkillRouter` macro, `Helpers` module. 49 routes self-describing. Zero breaking changes.
- **Build 95**: The Logic Monitor — Cognitive Flight Recording. 7 `:telemetry` events across OODA pipeline (start/step/done, llm call/parsed, tool start/stop). Rolling 50-event buffer with SSE pub/sub. Dark-themed dashboard at `/api/monitor`. Think Stream panel for real-time `<think>` block display. 3 new routes (52 total). Zero overhead when dashboard closed.
- **Build 96**: The Global Logic Tap — `Plug.Telemetry` on Endpoint captures every HTTP request. Monitor now shows [API] calls with method, path, status, duration, and response body (truncated 5KB). Responses panel, filter buttons (API/OODA/LLM/TOOL), status-code coloring. Every REST call from Claude Code is now a visible "thought" in the dashboard.
- **Build 97**: Metric Caching — heatmap/change_risk/god_modules cached in Knowledge.Store `metric_caches` map, warmed eagerly after graph rebuild via background Task (same pattern as graph build). Cache-first reads on handle_call, fallback to sync computation + cache on cold miss. Shared `build_coupling_map` across heatmap+change_risk via `compute_cached_metrics/2`. Target: <10ms warm reads (was 570-1166ms).
- **Build 98**: Discovery Engine — 3 discovery endpoints (`/api/discovery/skills`, `/categories`, `/search`), `__skills__/0` activated at runtime across all 9 routers. SKILL.md 349→~75 lines (90% context reduction). 55 total self-describing routes.
- **Build 99**: Complete Metric Caching — `dead_code` and `coupling` added to `compute_cached_metrics/2` with cache-first reads in Store. Single Sourceror pass via `collect_remote_calls/1` eliminates double-parse (coupling + coupling_map). New `dead_code_with_asts/3`, `coupling_from_calls/1`, `build_coupling_map_from_calls/1`. All 5 heavy metrics now sub-10ms on warm reads. Dashboard 100% green.
- **Build 100**: Semantic Tool Injection — Preflight now returns `suggested_tools` ranked by cosine similarity to prompt. SemanticIndex embeds all 55 skill intents from 9 routers, lazy-inits on first search. `search_skills/2` uses Nx.dot + Nx.top_k for ranking. Graceful degradation: returns `[]` if EmbeddingServing unavailable. Zero breaking changes to Preflight API.
- **Build 102-104**: AST Persistence + Merkle Tree — CubDB-backed persistence layer eliminates cold restarts. 4 new modules in `lib/giulia/persistence/`: `Store` (CubDB lifecycle per project), `Writer` (async write-behind with 100ms debounce batching), `Loader` (startup recovery with content-hash staleness detection), `Merkle` (SHA-256 Merkle tree for integrity verification). Warm start restores 93 AST entries + knowledge graph (1243 vertices, 1544 edges) + metric caches + embeddings (93 module + 626 function vectors) from disk — zero re-scanning. Cache stored at `{project}/.giulia/cache/cubdb/`. 2 new endpoints: `POST /api/index/verify` (Merkle integrity check), `POST /api/index/compact` (CubDB compaction). `/api/index/status` enriched with `cache_status` and `merkle_root`. Invalidation: build mismatch → cold start, file hash mismatch → incremental re-scan. 57 total routes.

## Next Steps

1. Verify Anthropic and Ollama providers work end-to-end
4. Implement Owl TUI for live streaming responses
5. Add constitution enforcement in reflection step
6. Expand test coverage (currently minimal)
7. Father-killing: Use Giulia to build Giulia's remaining features
8. Clean up legacy `cli.ex` (RPC-based) once HTTP client is proven
