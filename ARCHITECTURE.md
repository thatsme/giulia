# Giulia Architecture

## 1. Overview

Giulia is a high-performance, local-first AI development agent built in Elixir/OTP.
It runs as a persistent background daemon inside Docker, exposing an HTTP REST API
on port 4000. Any client -- Claude Code, a CLI escript, an editor plugin -- talks
to the daemon over plain HTTP/JSON. The daemon never restarts between terminal
sessions; it keeps AST caches, property graphs, and embedding vectors warm in
memory across invocations.

```
 +-----------+   +-----------+   +----------------+
 | Claude    |   | CLI       |   | Editor Plugin  |
 | Code      |   | (escript) |   | (future)       |
 +-----+-----+   +-----+-----+   +-------+--------+
       |               |                 |
       +-------+-------+-----------------+
               |
          HTTP / JSON
               |
               v
 +-----------------------------+
 |   giulia-worker  :4000      |
 |   (Bandit + Plug.Router)    |
 |   70 API endpoints          |
 +-----------------------------+
```

The daemon holds per-project state in ETS tables, a libgraph-based property graph,
CubDB persistence for warm restarts, and an optional ArcadeDB connection for
cross-build historical analysis.


## 2. Two-Node Model

Giulia ships as a single Docker image (`giulia/core:latest`). Two containers are
started from that image, differentiated by the `GIULIA_ROLE` environment variable:

```
+-------------------------------------------------------------------+
|  Docker Network                                                   |
|                                                                   |
|  +-----------------------------+    +---------------------------+ |
|  | giulia-worker               |    | giulia-monitor            | |
|  | GIULIA_ROLE=worker          |    | GIULIA_ROLE=monitor       | |
|  | Port 4000 (HTTP API)        |    | Port 4001 (HTTP API)      | |
|  | Port 4369 (EPMD)            |    | Port 4369 (EPMD)          | |
|  | Ports 9100-9105 (dist)      |    | Ports 9110-9115 (dist)    | |
|  |                             |    |                           | |
|  | - AST indexing              |    | - Distributed Erlang      | |
|  | - Property Graph           |    |   connection to worker    | |
|  | - Semantic search           |    | - Burst detection         | |
|  | - EmbeddingServing          |    | - High-frequency runtime  | |
|  | - Inference engine          |    |   snapshots               | |
|  | - 70 API endpoints          |    | - Performance profiling   | |
|  | - CubDB persistence         |    |                           | |
|  | - ArcadeDB L2 snapshots     |    | Skips:                    | |
|  |                             |    |  EmbeddingServing (~90MB) | |
|  |                             |    |  Inference pools           | |
|  |                             |    |  SemanticIndex             | |
|  +-------------+---------------+    +-------------+-------------+ |
|                |                                  |               |
|                +---- Erlang Distribution ----------+               |
|                      (cookie-authenticated)                       |
+-------------------------------------------------------------------+
                         |
                         | HTTP (host.docker.internal:2480)
                         v
               +-------------------+
               | ArcadeDB          |
               | (standalone)      |
               | Port 2480         |
               +-------------------+
```

**Worker** (`giulia-worker`): The primary daemon. Runs all static analysis (AST
scanning, property graph construction, semantic embeddings), the inference engine
(OODA loop with LLM providers), and serves all 70 API endpoints. Memory limit: 4GB.

**Monitor** (`giulia-monitor`): A lightweight observer node. Connects to the worker
via distributed Erlang on startup (AutoConnect GenServer). Its job is runtime
introspection: periodic BEAM health snapshots, burst detection (spikes in
reductions/memory), and performance profiling triggered by bursts. It skips
EmbeddingServing, SemanticIndex, and all Inference children to save approximately
200MB of RAM. Memory limit: 2GB.

The monitor `depends_on` the worker being healthy (curl health check on :4000 with
30s interval). Both containers share the same Erlang cookie (`GIULIA_COOKIE`,
default `giulia_dev`) for authenticated distribution.


## 3. OTP Supervision Tree

`Giulia.Application.start/2` detects whether it is running in client mode (thin
HTTP client, empty supervision tree) or daemon mode. In daemon mode, it starts
children under a single `:one_for_one` supervisor (`Giulia.Supervisor`) in four
tiers:

```
Giulia.Supervisor (:one_for_one)
|
|-- TIER 1: Base (always started)
|   |-- Registry (Elixir.Registry, :unique, name: Giulia.Registry)
|   |-- Context.Store (ETS tables for AST data)
|   |-- Persistence.Store (CubDB lifecycle, one instance per project)
|   |-- Persistence.Writer (async write-behind, 100ms debounce)
|   |-- Tools.Registry (auto-discovers tool modules on boot)
|   |-- Context.Indexer (background AST scanner, Task.async_stream)
|   |-- Knowledge.Store (libgraph in-memory directed graph)
|   |-- Storage.Arcade.Indexer (L2 graph sync on {:graph_ready})
|   +-- Storage.Arcade.Consolidator (periodic cross-build analysis)
|
|-- TIER 2: Heavy (skipped when GIULIA_ROLE=monitor)
|   |-- Intelligence.EmbeddingServing (Bumblebee + all-MiniLM-L6-v2)
|   +-- Intelligence.SemanticIndex (cosine similarity search)
|
|-- TIER 3: Inference (skipped when GIULIA_ROLE=monitor)
|   |-- Provider.Supervisor (DynamicSupervisor for LLM connections)
|   |-- Inference.Trace (debug storage for inference runs)
|   |-- Inference.Events (SSE event broadcaster)
|   |-- Inference.Approval (interactive consent gate)
|   +-- Inference.Supervisor (pools with back-pressure)
|
|-- TIER 4: Tail (always started)
|   |-- Monitor.Store (rolling event buffer + SSE pub/sub)
|   |-- Core.ProjectSupervisor (DynamicSupervisor for per-project contexts)
|   |-- Core.ContextManager (routes requests to correct ProjectContext)
|   |-- Runtime.Collector (periodic BEAM health snapshots)
|   |-- Runtime.IngestStore (Monitor->Worker snapshot pipeline)
|   |-- Runtime.Observer (async observation controller)
|   |-- Runtime.AutoConnect (returns :ignore if GIULIA_CONNECT_NODE unset)
|   +-- Runtime.Monitor (returns :ignore unless GIULIA_ROLE=monitor)
|
+-- Bandit (HTTP endpoint, skipped in MIX_ENV=test)
    plug: Giulia.Daemon.Endpoint
    port: GIULIA_PORT (default 4000)
```

After the supervisor starts successfully, `Giulia.Monitor.Telemetry.attach/0` hooks
`:telemetry` handlers for the cognitive flight recording system (7 events across the
OODA pipeline).


## 4. Storage Architecture

Giulia uses a three-tier storage model. Each tier serves a different latency and
durability requirement.

### L1 -- ETS + libgraph (sub-millisecond, volatile)

The hot path. All API reads hit L1 first.

- **Context.Store**: ETS table keyed by `{:ast, project_path, file_path}`. Stores
  parsed AST data, module metadata, function signatures, specs, callbacks, and
  struct definitions. Rebuilt on every scan.

- **Knowledge.Store**: An in-memory `Graph` (libgraph directed graph) holding module
  dependency relationships. Supports queries like dependents, dependencies,
  centrality, impact maps, and shortest path. Rebuilt after every scan from the AST
  data in Context.Store.

- **Metric caches**: Computed lazily and cached in Knowledge.Store's GenServer state.
  Five cached metrics: `heatmap`, `change_risk`, `god_modules`, `dead_code`,
  `coupling`. Warmed eagerly after graph rebuild via a background Task. Sub-10ms on
  warm reads (was 570-1166ms before caching).

### L2 -- CubDB (warm starts, per-project)

On-disk key-value store for surviving restarts without re-scanning.

- **Location**: `{project}/.giulia/cache/cubdb/` (one CubDB instance per project).
  In test mode (`MIX_ENV=test`), routed to `/tmp` to avoid corrupting the dev
  daemon's data.

- **Contents**: AST entries, serialized property graph, metric caches, embedding
  vectors (module + function).

- **Writer**: `Persistence.Writer` batches writes with a 100ms debounce. Multiple
  writes within the window are coalesced into a single CubDB transaction.

- **Loader**: `Persistence.Loader` restores L1 from L2 on startup. Detects stale
  files by comparing SHA-256 content hashes of source files against stored hashes.
  Stale entries trigger incremental re-scanning rather than a full rebuild.

- **Merkle tree**: `Persistence.Merkle` builds a SHA-256 Merkle tree over all cached
  entries. Used for integrity verification (`POST /api/index/verify`) and detecting
  corruption (if build version mismatches, the entire L2 cache is discarded and a
  cold start occurs).

### L3 -- ArcadeDB (history, consolidation)

External multi-model graph database for cross-build analysis. Not on the hot path.

- **Deployment**: Standalone container (`arcadedata/arcadedb:latest`) on port 2480.
  Not managed by the Giulia docker-compose file. Worker reaches it via
  `ARCADEDB_URL` (default: `http://host.docker.internal:2480`).

- **Query languages**: Cypher, SQL, and sqlscript. The Req-based HTTP client
  (`Giulia.Storage.Arcade.Client`) supports all three.

- **Schema**:
  - Vertex types: `Module`, `Function`, `File`, `Insight`
  - Edge types: `DEPENDS_ON`, `CALLS`, `DEFINED_IN`
  - All records carry `project`, `build_id`, and `indexed_at` fields
  - Composite unique indexes on `(project, name)` per vertex type

- **Indexer**: `Giulia.Storage.Arcade.Indexer` hooks into the `{:graph_ready}` event
  and snapshots the entire L1 graph into ArcadeDB after every successful build.

- **Consolidator**: `Giulia.Storage.Arcade.Consolidator` runs on a 30-minute
  schedule (or on-demand). Executes three algorithms across historical snapshots:
  `complexity_drift`, `coupling_drift` (fan-in/fan-out), and `hotspot` detection.
  Results are stored as `Insight` vertices.

- **Purpose**: ETS + libgraph stays L1 for real-time queries. ArcadeDB is for
  history -- trend analysis, regression detection, cross-build comparisons. Typical
  warm query latency is ~100ms, acceptable for L2/L3 but not the hot path.


## 5. AST + Runtime Fusion

The key differentiator of Giulia's architecture is the fusion of static code analysis
with live runtime data from the BEAM VM.

### Static Analysis Pipeline

```
.ex source files
    |
    v
Sourceror.parse_string/1        (pure Elixir AST parser)
    |
    v
Context.Store (ETS)             {:ast, project_path, file_path}
    |                           modules, functions, specs, structs
    v
Knowledge.Store (libgraph)      module dependency graph
    |                           edges from alias/import/use analysis
    v
Metric caches                   heatmap, complexity, coupling,
                                dead_code, god_modules, change_risk
```

### Runtime Introspection Pipeline

```
Target BEAM node (self or remote)
    |
    v
Runtime.Inspector               :erlang.memory/0, Process.info/2,
    |                           :erlang.statistics/1, :erlang.trace/3
    v
Runtime.Collector               periodic snapshots (configurable interval)
    |
    v
Burst detection                 spike in reductions/memory triggers
    |                           high-frequency capture mode
    v
Performance profiling           function-level trace during burst window
```

### Fusion Point

The `/api/runtime/hot_spots` endpoint is the fusion point. It:

1. Reads top processes from the target BEAM node (by reductions or memory)
2. Resolves PIDs to module names via `Process.info(pid, :dictionary)`
3. Looks up each module in the Property Graph for centrality, complexity, and zone
4. Returns a merged view: runtime activity annotated with static analysis metadata

The Observer (running on the monitor node) pushes snapshots to the worker via HTTP.
The worker finalizes each snapshot with static+runtime correlation.


## 6. Request Flow

A typical API request follows this path:

```
HTTP request
    |
    v
Bandit (HTTP server)
    |
    v
Plug.Telemetry                  emits [:giulia, :http] telemetry event
    |
    v
Plug.Logger
    |
    v
Plug.Router (:match, :fetch_query_params, Plug.Parsers)
    |
    v
Endpoint.ex                     core routes + forward declarations
    |
    +-- forward "/api/index"        --> Routers.Index
    +-- forward "/api/knowledge"    --> Routers.Knowledge
    +-- forward "/api/intelligence" --> Routers.Intelligence
    +-- forward "/api/runtime"      --> Routers.Runtime
    +-- forward "/api/search"       --> Routers.Search
    +-- forward "/api/transaction"  --> Routers.Transaction
    +-- forward "/api/approval"     --> Routers.Approval
    +-- forward "/api/monitor"      --> Routers.Monitor
    +-- forward "/api/discovery"    --> Routers.Discovery
    |
    v
Sub-router (e.g., Routers.Knowledge)
    |
    v
Helpers.send_json/3             JSON response encoding
Helpers.resolve_project_path/1  host-to-container path translation
    |
    v
GenServer.call to Knowledge.Store / Context.Store
    |
    v
ETS / libgraph lookup
    |
    v
JSON response
```

Core routes that remain in Endpoint.ex (not forwarded):
- `GET /health` -- health check (node name, version)
- `POST /api/command` -- main chat/command entry point
- `POST /api/command/stream` -- SSE streaming inference
- `POST /api/ping` -- lightweight path validation
- `GET /api/status` -- uptime, active project count
- `GET /api/projects` -- list active projects
- `POST /api/init` -- initialize a project context
- `GET /api/debug/paths` -- path mapping diagnostics
- `GET /api/agent/last_trace` -- last inference trace
- `GET /api/approvals` -- pending approval requests


## 7. Sub-Router Architecture (Build 94)

Before Build 94, Endpoint.ex was 1,331 lines containing all route handlers. The
refactoring split it into 9 domain-specific sub-routers, reducing Endpoint
to forwarding declarations plus core route handlers.

Each sub-router uses the `Giulia.Daemon.SkillRouter` macro:

```elixir
defmodule Giulia.Daemon.Routers.Knowledge do
  use Giulia.Daemon.SkillRouter

  @skill %{
    intent: "Get modules that depend on a given module",
    endpoint: "GET /api/knowledge/dependents",
    params: %{module: "Elixir module name"},
    returns: "List of dependent modules",
    category: "knowledge"
  }
  get "/dependents" do
    # ...
  end
end
```

The `use Giulia.Daemon.SkillRouter` macro provides:
- `use Plug.Router` with standard plugs (match, fetch_query_params, JSON parser)
- `import Giulia.Daemon.Helpers` for shared response/path functions
- `@skill` as an accumulate attribute for route metadata
- `__skills__/0` function generated at compile time (via `@before_compile`)

The `__skills__/0` function powers the Discovery Engine (`/api/discovery/skills`,
`/categories`, `/search`), which allows clients to discover available endpoints
at runtime without hardcoding route tables.

Sub-routers and their domains:

| Prefix              | Router                 | Routes | Domain                              |
|---------------------|------------------------|--------|-------------------------------------|
| /api/index          | Routers.Index          | 9      | Module/function index, scan, verify, compact, complexity |
| /api/knowledge      | Routers.Knowledge      | 23     | Graph queries, metrics, insights    |
| /api/intelligence   | Routers.Intelligence   | 5      | Briefing, preflight, architect, validate, report_rules |
| /api/runtime        | Routers.Runtime        | 16     | BEAM introspection, trace, connect, profiles, ingest, observations |
| /api/search         | Routers.Search         | 3      | Text search, semantic search        |
| /api/transaction    | Routers.Transaction    | 3      | Transactional file operations       |
| /api/approval       | Routers.Approval       | 2      | Interactive consent gate            |
| /api/monitor        | Routers.Monitor        | 6      | Dashboard, SSE stream, history, observe start/stop/status |
| /api/discovery      | Routers.Discovery      | 3      | Skill introspection, search         |

Note: `/api/briefing`, `/api/brief`, and `/api/plan` all forward to
`Routers.Intelligence` as aliases.


## 8. Semantic Search

Giulia embeds module and function descriptions into a vector space for semantic
similarity search.

**Model**: `sentence-transformers/all-MiniLM-L6-v2`, loaded via Bumblebee into an
`Nx.Serving` (`Intelligence.EmbeddingServing`). The model is approximately 90MB and
is the primary reason the monitor node skips this child.

**Indexing**: On every scan, `Intelligence.SemanticIndex` embeds all module
descriptions and function signatures. Vectors are stored in ETS and persisted to
CubDB (L2) for warm restarts.

**Search**: Given a query string, the serving generates an embedding vector. The
SemanticIndex computes cosine similarity against all stored vectors using `Nx.dot`,
then ranks results with `Nx.top_k`.

**Preflight integration**: The `/api/briefing/preflight` endpoint uses semantic
search to match a user's prompt against the 70 skill intents declared across all
sub-routers. The response includes a `suggested_tools` list ranked by cosine
similarity, allowing clients to discover which API endpoints are most relevant to
their current task. Graceful degradation: if EmbeddingServing is unavailable (model
failed to load, or running on monitor node), `suggested_tools` returns an empty list.


## 9. Path Translation

Giulia runs inside Docker but receives file paths from clients on the host machine.
Two modules handle path security and translation.

### PathMapper

`Giulia.Core.PathMapper` translates between host paths and container paths using a
prefix swap strategy.

```
Host:      D:/Development/GitHub/MyProject/lib/foo.ex
Container: /projects/MyProject/lib/foo.ex

Mapping:   GIULIA_HOST_PROJECTS_PATH="D:/Development/GitHub"
           Container prefix: /projects
```

The translation:
1. Normalizes Windows backslashes to forward slashes
2. Performs case-insensitive prefix matching (Windows drive letters)
3. Swaps the host prefix with `/projects`

The reverse translation (`to_host/1`) does the inverse for responses that include
file paths, so clients see paths they can open locally.

### PathSandbox

`Giulia.Core.PathSandbox` ensures Giulia can only access files under the project
root -- the directory containing `GIULIA.md` (the project constitution). It:

1. Expands the requested path to an absolute path (resolving `..`, symlinks)
2. Verifies the expanded path starts with the sandbox root
3. Rejects any path that escapes containment

This prevents the LLM from requesting reads of `/etc/passwd`, `~/.ssh/config`, or
any file outside the project boundary, regardless of how the path is constructed.
