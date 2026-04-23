# Giulia Architecture

> **Document version**: Build 155 · v0.2.2 · 2026-04-23
>
> This document describes the architecture as of the build above. If the build
> counter in `mix.exs` is higher, sections may be out of date — re-audit against
> the codebase.

## 1. Overview

Giulia is a persistent, local-first code intelligence daemon built in Elixir/OTP.
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
          HTTP / JSON  or  MCP
               |
               v
 +-----------------------------+
 |   giulia-worker  :4000      |
 |   (Bandit + Plug.Router)    |
 |   85 API endpoints          |
 |   MCP server (/mcp)         |
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
|  | - 85 API endpoints          |    | - Performance profiling   | |
|  | - MCP server (71 tools)     |    |                           | |
|  | - CubDB persistence         |    | Skips:                    | |
|  | - ArcadeDB L2 snapshots     |    |  EmbeddingServing (~90MB) | |
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
(OODA loop with LLM providers), and serves all 85 API endpoints. Memory limit: 4GB.

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
children under a single `:one_for_one` supervisor (`Giulia.Supervisor`) in five
tiers:

```
Giulia.Supervisor (:one_for_one)
|
|-- TIER 1: Base (always started)
|   |-- Registry (Elixir.Registry, :unique, name: Giulia.Registry)
|   |-- Task.Supervisor (name: Giulia.TaskSupervisor)
|   |-- Context.Store (ETS tables for AST data)
|   |-- Persistence.Store (CubDB lifecycle, one instance per project)
|   |-- Persistence.Writer (async write-behind, 100ms debounce)
|   |-- Tools.Registry (auto-discovers tool modules on boot)
|   |-- Context.Indexer (background AST scanner, Task.async_stream)
|   |-- Knowledge.Store (libgraph in-memory directed graph)
|   |-- Persistence.WarmRestore (boot-time L2→L1 restore, non-blocking)
|   |-- Storage.Arcade.Indexer (L3 graph sync on {:graph_ready})
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
|-- TIER 5: MCP (only started if GIULIA_MCP_KEY is set)
|   +-- Giulia.MCP.Server (Anubis StreamableHTTP transport)
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

- **WarmRestore**: `Persistence.WarmRestore` is the startup driver. On boot it
  walks `/projects/*` (and `GIULIA_PROJECTS_PATH` if set) for directories
  containing the role-specific `.giulia/cache/cubdb[_<role>]/` layout and
  calls `Loader.restore_graph/1` + `restore_metrics/1` for each. The work runs
  in `handle_info(:run, _)` scheduled from `init/1` via `send/2` so supervisor
  start isn't blocked on I/O. This is what keeps `/api/projects` populated
  across `docker compose restart` without forcing a scan.

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
Giulia.AST.Extraction           Macro.traverse/4 with enclosing-module
    |                           stack — recognizes defmodule / defprotocol
    |                           / defimpl; nested names qualified
    |                           (Outer.Inner, three levels deep);
    |                           function_info carries :module so sibling
    |                           modules don't collapse on {name, arity}
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

### Knowledge Graph Internals

The Knowledge layer is not a single module. `Knowledge.Store` is the GenServer
coordinator, but the actual logic is split across purpose-built modules:

| Module | Responsibility |
|--------|---------------|
| `Knowledge.Builder` | Graph construction from AST data (4-pass pure functions) |
| `Knowledge.Topology` | Pure graph traversal: stats, centrality, reachability, cycles, paths |
| `Knowledge.Metrics` | Quantitative metrics: heatmap, change_risk, god_modules, dead_code, coupling |
| `Knowledge.Behaviours` | Behaviour integrity checking (callback validation, macro-aware) |
| `Knowledge.Conventions` | Convention violation detection via AST (Tier 1 metadata + Tier 2 patterns) |
| `Knowledge.Insights` | High-level code insights: orphan specs, logic flow, style oracle |
| `Knowledge.Insights.Impact` | Pre-impact risk analysis for rename/remove/refactor operations |
| `Knowledge.Analyzer` | Facade delegating to Topology, Metrics, Behaviours, Insights |
| `Knowledge.MacroMap` | Static mapping of `use Module` to injected function signatures |
| `Knowledge.Store.Reader` | Direct ETS reads bypassing GenServer (concurrent bulk reads) |

`Knowledge.Store` orchestrates: it owns the `Graph` struct in its state, delegates
computation to the pure modules above, and caches results in its state map. The
`Store.Reader` module provides a fast path for bulk extraction (all_modules,
all_functions, all_dependencies) that reads directly from ETS without going through
the GenServer mailbox.

### Intelligence Layer

Beyond embedding and search, the Intelligence layer provides four briefing and
validation modules used by the API:

| Module | Responsibility |
|--------|---------------|
| `Intelligence.ArchitectBrief` | Single-call project briefing with topology and health metrics |
| `Intelligence.Preflight` | Contract checklist pipeline (6 sections) with semantic tool ranking |
| `Intelligence.SurgicalBriefing` | Layer 1+2 preprocessing: semantic search + knowledge graph enrichment |
| `Intelligence.PlanValidator` | Graph-aware validation for code change plans (cycles, hub risk, blast radius) |

### MCP Layer (Build 155)

Giulia exposes a native Model Context Protocol (MCP) server alongside the REST API.
MCP enables AI assistants like Claude Code to discover and call Giulia's tools
directly as structured tool calls, without constructing HTTP requests.

| Module | Responsibility |
|--------|---------------|
| `MCP.Server` | Anubis MCP server — handles `tools/call`, `tools/list`, `resources/read` |
| `MCP.ToolSchema` | Auto-generates 71 MCP tool definitions from `@skill` annotations on sub-routers (74 skills minus 3 non-MCP-compatible HTML/SSE monitor endpoints) |
| `MCP.ResourceProvider` | 5 resource templates (`giulia://projects/`, `giulia://modules/`, `giulia://graph/`, `giulia://skills/`, `giulia://status`) |
| `Daemon.Plugs.McpAuth` | Bearer token authentication via `GIULIA_MCP_KEY` env var (constant-time comparison) |
| `Daemon.Plugs.McpForward` | Runtime forwarder to Anubis StreamableHTTP transport (defers init to avoid persistent_term race) |

The MCP server is conditional — it only starts if `GIULIA_MCP_KEY` is set.
Tool schemas are generated at boot from the same `@skill` annotations that power
the Discovery API, ensuring REST and MCP always expose identical capabilities.

Client configuration (`.mcp.json`):
```json
{
  "mcpServers": {
    "giulia": {
      "type": "http",
      "url": "http://localhost:4000/mcp",
      "headers": {
        "Authorization": "Bearer <GIULIA_MCP_KEY value>"
      }
    }
  }
}
```

### Runtime Layer

The Runtime subsystem has grown beyond the core Inspector + Collector pair:

| Module | Responsibility |
|--------|---------------|
| `Runtime.Inspector` | BEAM introspection via :erlang APIs (memory, stats, processes) |
| `Runtime.Inspector.Trace` | Short-lived per-module call tracing with 5-second kill switch |
| `Runtime.Collector` | Periodic snapshot collector with burst detection (IDLE/CAPTURING FSM) |
| `Runtime.Profiler` | Performance profile generator (template-based, offline, pure functions) |
| `Runtime.IngestStore` | Buffers runtime snapshots from Monitor, fuses with static knowledge data |
| `Runtime.Observer` | Observation controller for async collection sessions and HTTP push |
| `Runtime.AutoConnect` | Auto-connect to target BEAM node on startup with exponential backoff |
| `Runtime.Monitor` | Monitor lifecycle orchestrator (BOOT -> CONNECT -> WATCH -> PROFILING) |


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
    +-- forward "/api/briefing"     --> Routers.Intelligence  (alias)
    +-- forward "/api/brief"        --> Routers.Intelligence  (alias)
    +-- forward "/api/plan"         --> Routers.Intelligence  (alias)
    +-- forward "/api/runtime"      --> Routers.Runtime
    +-- forward "/api/search"       --> Routers.Search
    +-- forward "/api/transaction"  --> Routers.Transaction
    +-- forward "/api/approval"     --> Routers.Approval
    +-- forward "/api/monitor"      --> Routers.Monitor
    +-- forward "/api/discovery"    --> Routers.Discovery
    +-- forward "/mcp"             --> Plugs.McpForward (MCP protocol)
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
- `GET /favicon.ico` -- static favicon


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
| /api/knowledge      | Routers.Knowledge      | 25     | Graph queries, metrics, insights, topology, conventions |
| /api/intelligence   | Routers.Intelligence   | 5      | Briefing, preflight, architect, validate, report_rules |
| /api/runtime        | Routers.Runtime        | 16     | BEAM introspection, trace, connect, profiles, ingest, observations |
| /api/search         | Routers.Search         | 3      | Text search, semantic search, semantic status |
| /api/transaction    | Routers.Transaction    | 3      | Transactional file operations       |
| /api/approval       | Routers.Approval       | 2      | Interactive consent gate            |
| /api/monitor        | Routers.Monitor        | 7      | Dashboard, Graph Explorer, SSE stream, history, observe start/stop/status |
| /api/discovery      | Routers.Discovery      | 4      | Skill introspection, search, report rules |
| *(core endpoint)*   | Endpoint               | 11     | health, command, ping, status, projects, init, debug, trace, approvals |

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
search to match a user's prompt against the skill intents declared across all
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


## 10. Visual Dashboards (Build 95, 151, 152)

Giulia ships two browser-based dashboards, both served as static HTML from the
daemon's `/api/monitor` prefix.

### Logic Monitor (`/api/monitor`)

Real-time telemetry dashboard. Every HTTP request, inference step, LLM call, and
tool execution emits a `:telemetry` event, captured by `Monitor.Telemetry` handlers
and pushed to `Monitor.Store` (a rolling 50-event buffer with SSE pub/sub).

Features:
- **SSE streaming**: live event feed via `/api/monitor/stream`
- **Category filters**: API, OODA, LLM, TOOL — toggle visibility per event type
- **Project scoping**: dropdown auto-populated from events, filters by project path
- **Endpoint exclusion**: right-click to exclude noisy paths (persisted in localStorage)
- **Response panel**: click any API event to see its JSON response body
- **Think Stream**: real-time display of LLM `<think>` blocks during inference
- **Cache/Graph panels**: live project health (Merkle root, graph stats, top hubs)
- **Scans panel**: scan event history with warm/cold/incremental badges

Events carry a `project` field (extracted from HTTP `?path=` params via PathMapper,
or from inference metadata). This enables per-project filtering when multiple
codebases are being analyzed concurrently.

### Graph Explorer (`/api/monitor/graph`)

Interactive dependency graph visualization powered by Cytoscape.js (loaded from CDN).
Data source: `GET /api/knowledge/topology` returns the full module graph in
Cytoscape-ready format (nodes with heatmap scores/centrality, edges with labels).

Four view modes:
- **Dependency**: full module topology, nodes colored by heatmap zone, sized by fan-in
- **Heatmap**: emphasizes red/yellow modules, dims healthy green nodes
- **Blast Radius**: click any module to highlight depth-1 (orange) and depth-2 (blue) impact
- **Hub Map**: highlights high-degree modules, dims low-degree periphery

Layout options: force-directed (cose), hierarchical (breadthfirst), circle, concentric.
Click any node for a details panel showing score, zone, fan-in/out, complexity, and
test status. Hover to highlight connected edges.

The topology endpoint combines data from three sources in a single call:
1. `Knowledge.Store.all_dependencies/1` — edge list with labels
2. `Knowledge.Store.heatmap/1` — per-module scores and zones
3. `Knowledge.Store.find_fan_in_out/1` — centrality data

Both dashboards share a navigation bar for switching between Monitor and Graph
Explorer views.


## 11. Correctness-Floor Invariants

Giulia enforces cross-store sync and extraction-output stability through three
test-surface layers that ship alongside the code. Each catches a different
class of regression that property-style or example-style tests miss on their
own.

### L1↔L2↔L3 Verifier Endpoints

`Giulia.Persistence.Verifier` and `Giulia.Storage.Arcade.Verifier` implement
round-trip integrity checks between the three storage tiers. They're exposed
both as HTTP endpoints for live-daemon use and as mix-test jobs for CI:

- `GET /api/knowledge/verify_l2?path=...&check=all` — L1 ETS ↔ L2 CubDB
  round-trip for graph, AST, and metric caches. Vertex-set parity, edge-count
  parity, and stratified sample identity per payload.
- `GET /api/knowledge/verify_l3?path=...&sample_per_bucket=N` — L1 → L3
  ArcadeDB CALLS. Stratified sample across `:via` buckets (`:direct`,
  `:alias_resolved`, `:erlang_atom`, `:local`) plus a `?`/`!` orthogonal
  cross-cut, and total-count parity.
- `test/giulia/persistence/verifier_test.exs` (11 tests) and
  `test/giulia/storage/arcade/verifier_test.exs` (4 tests) drive the same
  verifier functions from mix test, with both happy-path assertions and
  drift-detection cases (deliberately corrupted L2/L3 state that the
  verifier must classify correctly).

### Filter-Accountability Regression Tests

For every filter predicate in a cross-store pipeline, both sides are tested:
**drop-side fixtures** parametric over the filter's criteria, AND
**pass-through fixtures** strictly larger than the drop set. Pass-through is
what catches silent over-match — a predicate that rejects more than it claims
to. Applied to four surfaces, this pattern caught 11 distinct silent-over-match
bugs on first run (`Indexer.ignored?/1` multi-segment dir, `ToolSchema.mcp_
compatible?/1` `/stream` substring, `Conventions.check_try_rescue_flow_control/
3` source-text `String.contains?`, `Topology.fuzzy_score/2` empty-needle
`String.contains?(_, "") == true`).

### Property Tests + Golden Fixtures

`StreamData` properties cover the pure-function layer: `Knowledge.Builder.
build_graph/1` (determinism, module vertex parity, function vertex coverage,
label sanity), `Topology.fuzzy_score/2` (bounded tier set, empty-needle
absorbent, reflexive 100), `Conventions.walk_ast/3` (determinism, no-crash on
generated Elixir, violations well-formed), and the extraction passes
themselves (module/function shape, per-module attribution).

Golden fixtures in `test/fixtures/extraction/` freeze the full `file_info`
output from `Processor.analyze/2` for six curated source cases (predicate/
bang names, default args, moduledoc variants, framework callbacks, protocols
+ defimpl, nested modules, macros + guards). Any drift in extraction output
produces a visible diff against the frozen `.expected.exs` that the reviewer
must ratify. Regeneration: `GOLDEN_UPDATE=1 mix test test/giulia/ast/golden_
fixtures_test.exs`.

