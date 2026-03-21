# Giulia REST API Reference

Complete reference for all REST API endpoints exposed by the Giulia daemon on port 4000.

**Base URL:** `http://localhost:4000`

**Content-Type:** All POST endpoints accept `application/json`. All responses return `application/json` unless otherwise noted.

**Path Convention:** Most GET endpoints under `/api/index` and `/api/knowledge` require `?path=P` where `P` is the host-side project path (e.g., `C:/Development/GitHub/MyApp`). POST endpoints take `path` in the JSON body. The `PathMapper` translates host paths to container paths automatically.

**Authentication:** None. Giulia is a local development tool designed for localhost access only. It is not designed for network exposure -- do not bind to 0.0.0.0 or expose port 4000 to untrusted networks. See [SECURITY.md](SECURITY.md) for the full threat model.

---

## Table of Contents

1. [Core](#core) (10 endpoints)
2. [Index](#index) (9 endpoints)
3. [Knowledge](#knowledge) (23 endpoints)
4. [Intelligence](#intelligence) (5 endpoints)
5. [Runtime](#runtime) (16 endpoints)
6. [Search](#search) (3 endpoints)
7. [Transaction](#transaction) (3 endpoints)
8. [Approval](#approval) (2 endpoints)
9. [Monitor](#monitor) (6 endpoints)
10. [Discovery](#discovery) (3 endpoints)

---

## Core

Root-level endpoints defined in `Giulia.Daemon.Endpoint`. These handle health checks, command execution, project management, and debugging.

### GET /health

Health check. Returns daemon status, Erlang node name, and version.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/health
```

**Response:**

```json
{
  "status": "ok",
  "node": "worker@giulia-worker",
  "version": "0.6.0-build.137"
}
```

---

### POST /api/command

Main command endpoint. Accepts either a structured command or a free-text chat message for LLM inference.

**Parameters (JSON body):**

| Field     | Required | Description                                    |
|-----------|----------|------------------------------------------------|
| `message` | Yes*     | Free-text prompt for LLM inference             |
| `command` | Yes*     | Structured command (`init`, `status`, `projects`) |
| `path`    | Yes      | Host-side project path                         |

*One of `message` or `command` is required.

**Example (chat):**

```bash
curl -X POST http://localhost:4000/api/command \
  -H "Content-Type: application/json" \
  -d '{"message": "List all modules", "path": "C:/Development/GitHub/Giulia"}'
```

**Response:**

```json
{
  "status": "ok",
  "response": "Indexed modules:\n- Giulia.Application\n- Giulia.Client\n..."
}
```

---

### POST /api/command/stream

SSE streaming inference. Returns a chunked `text/event-stream` response with real-time inference steps.

**Parameters (JSON body):**

| Field     | Required | Description                |
|-----------|----------|----------------------------|
| `message` | Yes      | Free-text prompt           |
| `path`    | Yes      | Host-side project path     |

**Example:**

```bash
curl -N -X POST http://localhost:4000/api/command/stream \
  -H "Content-Type: application/json" \
  -d '{"message": "Explain the supervision tree", "path": "C:/Development/GitHub/Giulia"}'
```

**Response (SSE):**

```
event: start
data: {"request_id": "#Ref<0.1234.5.6>"}

event: step
data: {"type": "think", "content": "..."}

event: complete
data: {"type": "complete", "response": "The supervision tree..."}
```

---

### POST /api/ping

Lightweight ping. Checks whether a project context is active for the given path.

**Parameters (JSON body):**

| Field  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl -X POST http://localhost:4000/api/ping \
  -H "Content-Type: application/json" \
  -d '{"path": "C:/Development/GitHub/Giulia"}'
```

**Response:**

```json
{
  "status": "ok",
  "path": "/projects/Giulia"
}
```

---

### GET /api/status

Daemon status. Returns node name, uptime, and active project count.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/status
```

**Response:**

```json
{
  "node": "worker@giulia-worker",
  "started_at": "2026-03-16T10:00:00Z",
  "uptime_seconds": 0,
  "active_projects": 2
}
```

---

### GET /api/projects

List all active project contexts managed by the daemon.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/projects
```

**Response:**

```json
{
  "projects": [
    {"path": "/projects/Giulia", "pid": "#PID<0.500.0>"},
    {"path": "/projects/MyApp", "pid": "#PID<0.600.0>"}
  ]
}
```

---

### POST /api/init

Initialize a project context. Scans for `GIULIA.md` and starts a `ProjectContext` GenServer.

**Parameters (JSON body):**

| Field  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |
| `opts` | No       | Initialization options (map) |

**Example:**

```bash
curl -X POST http://localhost:4000/api/init \
  -H "Content-Type: application/json" \
  -d '{"path": "C:/Development/GitHub/MyApp"}'
```

**Response:**

```json
{
  "status": "initialized",
  "path": "/projects/MyApp"
}
```

---

### GET /api/debug/paths

Debug endpoint. Shows current path mappings between host and container paths.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/debug/paths
```

**Response:**

```json
{
  "in_container": true,
  "mappings": [
    {"host": "C:/Development/GitHub", "container": "/projects"}
  ]
}
```

---

### GET /api/agent/last_trace

Returns the last inference trace (OODA loop steps, tool calls, timing).

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/agent/last_trace
```

**Response:**

```json
{
  "trace": {
    "steps": ["think", "validate", "execute"],
    "tool_calls": [...],
    "duration_ms": 2340
  }
}
```

---

### GET /api/approvals

List all pending approval requests from the inference consent gate.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/approvals
```

**Response:**

```json
{
  "pending": [],
  "count": 0
}
```

---

## Index

AST index endpoints backed by ETS. Managed by `Giulia.Daemon.Routers.Index`.

### GET /api/index/modules

List all indexed modules in a project.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/index/modules?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "modules": [
    {"name": "Giulia.Application", "file": "lib/giulia/application.ex"},
    {"name": "Giulia.Client", "file": "lib/giulia/client.ex"}
  ],
  "count": 138
}
```

---

### GET /api/index/functions

List functions in a project, optionally filtered by module.

**Parameters (query string):**

| Param    | Required | Description                        |
|----------|----------|------------------------------------|
| `path`   | Yes      | Host-side project path             |
| `module` | No       | Filter by module name (e.g., `Giulia.Tools.Registry`) |

**Example:**

```bash
curl "http://localhost:4000/api/index/functions?path=C:/Development/GitHub/Giulia&module=Giulia.Tools.Registry"
```

**Response:**

```json
{
  "functions": [
    {"name": "register", "arity": 1, "module": "Giulia.Tools.Registry", "type": "def", "line": 42},
    {"name": "list_tools", "arity": 0, "module": "Giulia.Tools.Registry", "type": "def", "line": 55}
  ],
  "count": 2,
  "module": "Giulia.Tools.Registry"
}
```

---

### GET /api/index/module_details

Full module metadata including file path, moduledoc, functions, types, specs, callbacks, and struct fields.

**Parameters (query string):**

| Param    | Required | Description            |
|----------|----------|------------------------|
| `path`   | Yes      | Host-side project path |
| `module` | Yes      | Module name            |

**Example:**

```bash
curl "http://localhost:4000/api/index/module_details?path=C:/Development/GitHub/Giulia&module=Giulia.Tools.Registry"
```

**Response:**

```json
{
  "module": "Giulia.Tools.Registry",
  "details": {
    "file": "lib/giulia/tools/registry.ex",
    "moduledoc": "Auto-discovers tools on boot",
    "functions": [...],
    "types": [...],
    "specs": [...],
    "callbacks": [],
    "struct": null
  }
}
```

---

### GET /api/index/summary

Project shape overview with aggregate counts.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/index/summary?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "summary": "138 modules, 1418 functions, 95 types, 312 specs, 14 structs, 28 callbacks"
}
```

---

### GET /api/index/status

Indexer status including scan state, cache warmth, and Merkle root.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/index/status
```

**Response:**

```json
{
  "state": "idle",
  "project_path": "/projects/Giulia",
  "file_count": 138,
  "last_scan": "2026-03-16T10:05:00Z",
  "cache_status": "warm",
  "merkle_root": "a1b2c3d4e5f6"
}
```

---

### POST /api/index/scan

Trigger a full re-index of a project. Scans all `.ex` files, builds AST entries, knowledge graph, and embeddings.

**Parameters (JSON body):**

| Field  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl -X POST http://localhost:4000/api/index/scan \
  -H "Content-Type: application/json" \
  -d '{"path": "C:/Development/GitHub/Giulia"}'
```

**Response:**

```json
{
  "status": "scanning",
  "path": "/projects/Giulia"
}
```

---

### POST /api/index/verify

Merkle tree integrity verification. Recomputes hashes and compares against stored tree.

**Parameters (JSON body):**

| Field  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl -X POST http://localhost:4000/api/index/verify \
  -H "Content-Type: application/json" \
  -d '{"path": "C:/Development/GitHub/Giulia"}'
```

**Response:**

```json
{
  "status": "ok",
  "verified": true,
  "root": "a1b2c3d4e5f6",
  "leaf_count": 138
}
```

---

### POST /api/index/compact

Trigger CubDB compaction to reclaim disk space from the persistence layer.

**Parameters (JSON body):**

| Field  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl -X POST http://localhost:4000/api/index/compact \
  -H "Content-Type: application/json" \
  -d '{"path": "C:/Development/GitHub/Giulia"}'
```

**Response:**

```json
{
  "status": "compacting",
  "path": "/projects/Giulia"
}
```

---

### GET /api/index/complexity

Rank functions by cognitive complexity (Sonar-style, nesting-aware scoring).

**Parameters (query string):**

| Param    | Required | Description                              |
|----------|----------|------------------------------------------|
| `path`   | Yes      | Host-side project path                   |
| `module` | No       | Filter by module name                    |
| `min`    | No       | Minimum complexity threshold (default: 0) |
| `limit`  | No       | Max results to return (default: 50)      |

**Example:**

```bash
curl "http://localhost:4000/api/index/complexity?path=C:/Development/GitHub/Giulia&min=5&limit=10"
```

**Response:**

```json
{
  "functions": [
    {"name": "build", "arity": 2, "module": "Giulia.Knowledge.Store", "complexity": 24, "line": 150},
    {"name": "run", "arity": 3, "module": "Giulia.Intelligence.Preflight", "complexity": 18, "line": 42}
  ],
  "count": 10,
  "module": null,
  "min_complexity": 5
}
```

---

## Knowledge

Knowledge Graph topology analysis endpoints. Managed by `Giulia.Daemon.Routers.Knowledge`. This is the largest category with 23 endpoints.

All GET endpoints require `?path=P` in the query string.

### GET /api/knowledge/stats

Graph statistics: vertex/edge counts, connected components, top hub modules.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/stats?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "vertices": 1243,
  "edges": 1544,
  "components": 3,
  "hubs": [
    {"module": "Giulia.Knowledge.Store", "degree": 28},
    {"module": "Giulia.Daemon.Helpers", "degree": 15}
  ]
}
```

---

### GET /api/knowledge/dependents

Find all modules that depend on a given module (downstream blast radius).

**Parameters (query string):**

| Param    | Required | Description            |
|----------|----------|------------------------|
| `path`   | Yes      | Host-side project path |
| `module` | Yes      | Target module name     |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/dependents?path=C:/Development/GitHub/Giulia&module=Giulia.Daemon.Helpers"
```

**Response:**

```json
{
  "module": "Giulia.Daemon.Helpers",
  "dependents": [
    "Giulia.Daemon.Routers.Index",
    "Giulia.Daemon.Routers.Knowledge",
    "Giulia.Daemon.Routers.Runtime"
  ],
  "count": 9
}
```

---

### GET /api/knowledge/dependencies

Find all modules that a given module depends on (upstream dependencies).

**Parameters (query string):**

| Param    | Required | Description            |
|----------|----------|------------------------|
| `path`   | Yes      | Host-side project path |
| `module` | Yes      | Target module name     |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/dependencies?path=C:/Development/GitHub/Giulia&module=Giulia.Daemon.Routers.Index"
```

**Response:**

```json
{
  "module": "Giulia.Daemon.Routers.Index",
  "dependencies": [
    "Giulia.Daemon.Helpers",
    "Giulia.Context.Store",
    "Giulia.Context.Indexer",
    "Giulia.Core.PathMapper"
  ],
  "count": 4
}
```

---

### GET /api/knowledge/centrality

Hub detection score for a module: in-degree, out-degree, and dependent list.

**Parameters (query string):**

| Param    | Required | Description            |
|----------|----------|------------------------|
| `path`   | Yes      | Host-side project path |
| `module` | Yes      | Target module name     |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/centrality?path=C:/Development/GitHub/Giulia&module=Giulia.Knowledge.Store"
```

**Response:**

```json
{
  "module": "Giulia.Knowledge.Store",
  "in_degree": 28,
  "out_degree": 5,
  "dependents": ["Giulia.Daemon.Routers.Knowledge", "..."]
}
```

---

### GET /api/knowledge/impact

Full impact map: upstream and downstream dependencies at a given depth, with function-level edges.

**Parameters (query string):**

| Param    | Required | Description                      |
|----------|----------|----------------------------------|
| `path`   | Yes      | Host-side project path           |
| `module` | Yes      | Target module name               |
| `depth`  | No       | Traversal depth (default: 2)     |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/impact?path=C:/Development/GitHub/Giulia&module=Giulia.Tools.Registry&depth=2"
```

**Response:**

```json
{
  "module": "Giulia.Tools.Registry",
  "upstream": [
    {"module": "Giulia.Context.Builder", "depth": 1}
  ],
  "downstream": [
    {"module": "Giulia.Inference.Orchestrator", "depth": 1},
    {"module": "Giulia.Inference.Pool", "depth": 2}
  ],
  "function_edges": [
    {"function": "register/1", "calls": ["Giulia.Tools.ReadFile"]}
  ]
}
```

---

### GET /api/knowledge/integrity

Behaviour-implementer integrity check. Detects missing or extra callbacks.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/integrity?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "status": "fractured",
  "fractures": [
    {
      "behaviour": "Giulia.Provider",
      "fractures": [
        {"implementor": "Giulia.Provider.Ollama", "missing": ["stream/3"], "extra": []}
      ]
    }
  ]
}
```

---

### GET /api/knowledge/dead_code

Detect functions that are defined but never called anywhere in the project.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/dead_code?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "dead_functions": [
    {"module": "Giulia.Tools.Think", "function": "unused_helper", "arity": 1, "line": 45}
  ],
  "count": 12
}
```

---

### GET /api/knowledge/cycles

Detect circular dependencies (strongly connected components with more than one member).

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/cycles?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "cycles": [
    ["Giulia.Context.Store", "Giulia.Knowledge.Store"]
  ],
  "count": 1
}
```

---

### GET /api/knowledge/god_modules

Detect god modules: high complexity, high centrality, and high function count.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/god_modules?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "god_modules": [
    {"module": "Giulia.Knowledge.Store", "function_count": 45, "complexity": 320, "degree": 28}
  ],
  "count": 1
}
```

---

### GET /api/knowledge/orphan_specs

Detect orphan specs: `@spec` declarations without a matching function definition.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/orphan_specs?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "orphan_specs": [
    {"module": "Giulia.Provider.Ollama", "spec": "stream/3"}
  ],
  "count": 1
}
```

---

### GET /api/knowledge/fan_in_out

Analyze fan-in/fan-out per module. Reveals dependency direction imbalance.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/fan_in_out?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "modules": [
    {"module": "Giulia.Daemon.Helpers", "fan_in": 9, "fan_out": 2, "ratio": 4.5}
  ],
  "count": 138
}
```

---

### GET /api/knowledge/coupling

Function-level dependency strength between module pairs.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/coupling?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "pairs": [
    {"from": "Giulia.Daemon.Endpoint", "to": "Giulia.Daemon.Helpers", "strength": 12}
  ],
  "count": 45
}
```

---

### GET /api/knowledge/api_surface

Public vs private function ratio per module.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/api_surface?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "modules": [
    {"module": "Giulia.Knowledge.Store", "public": 23, "private": 12, "ratio": 0.66}
  ],
  "count": 138
}
```

---

### GET /api/knowledge/change_risk

Composite refactoring priority score per module. Combines centrality, complexity, coupling, and coverage.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/change_risk?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "modules": [
    {"module": "Giulia.Knowledge.Store", "risk_score": 87, "factors": {"centrality": 28, "complexity": 320}}
  ],
  "count": 138
}
```

---

### GET /api/knowledge/path

Shortest path between two modules in the dependency graph.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |
| `from` | Yes      | Source module name     |
| `to`   | Yes      | Target module name     |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/path?path=C:/Development/GitHub/Giulia&from=Giulia.Client&to=Giulia.Tools.Registry"
```

**Response:**

```json
{
  "from": "Giulia.Client",
  "to": "Giulia.Tools.Registry",
  "path": ["Giulia.Client", "Giulia.Daemon.Endpoint", "Giulia.Tools.Registry"],
  "hops": 2
}
```

---

### GET /api/knowledge/logic_flow

Function-level Dijkstra path between two MFA (Module.function/arity) vertices.

**Parameters (query string):**

| Param  | Required | Description                               |
|--------|----------|-------------------------------------------|
| `path` | Yes      | Host-side project path                    |
| `from` | Yes      | Source MFA (e.g., `Giulia.Client.main/1`) |
| `to`   | Yes      | Target MFA                                |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/logic_flow?path=C:/Development/GitHub/Giulia&from=Giulia.Client.main/1&to=Giulia.Tools.Registry.list_tools/0"
```

**Response:**

```json
{
  "from": "Giulia.Client.main/1",
  "to": "Giulia.Tools.Registry.list_tools/0",
  "steps": [
    "Giulia.Client.main/1",
    "Giulia.Client.send_request/2",
    "Giulia.Tools.Registry.list_tools/0"
  ],
  "hop_count": 2
}
```

---

### GET /api/knowledge/style_oracle

Find exemplar functions by concept with a quality gate (requires both `@spec` and `@doc`).

**Parameters (query string):**

| Param   | Required | Description                             |
|---------|----------|-----------------------------------------|
| `path`  | Yes      | Host-side project path                  |
| `q`     | Yes      | Concept to search for                   |
| `top_k` | No       | Number of results to return (default: 3) |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/style_oracle?path=C:/Development/GitHub/Giulia&q=error%20handling&top_k=5"
```

**Response:**

```json
{
  "exemplars": [
    {
      "module": "Giulia.Core.PathSandbox",
      "function": "validate/2",
      "score": 0.92,
      "has_spec": true,
      "has_doc": true
    }
  ],
  "count": 3
}
```

---

### POST /api/knowledge/pre_impact_check

Analyze rename/remove risk with callers, risk score, and phased migration plan.

**Parameters (JSON body):**

| Field      | Required | Description                                                      |
|------------|----------|------------------------------------------------------------------|
| `path`     | Yes      | Host-side project path                                           |
| `module`   | Yes      | Target module name                                               |
| `action`   | Yes      | One of: `rename_function`, `remove_function`, `rename_module`    |
| `target`   | No       | Function target in `name/arity` format (for function actions)    |
| `new_name` | No       | New name (for rename actions)                                    |

**Example:**

```bash
curl -X POST http://localhost:4000/api/knowledge/pre_impact_check \
  -H "Content-Type: application/json" \
  -d '{"path": "C:/Development/GitHub/Giulia", "module": "Giulia.Tools.Registry", "action": "rename_function", "target": "register/1", "new_name": "register_tool"}'
```

**Response:**

```json
{
  "action": "rename_function",
  "target": "register/1",
  "risk_score": "medium",
  "affected_callers": [
    {"module": "Giulia.Tools.ReadFile", "function": "init/0", "line": 12}
  ],
  "migration_plan": [
    "Step 1: Add register_tool/1 as alias",
    "Step 2: Update 3 callers",
    "Step 3: Remove register/1"
  ]
}
```

---

### GET /api/knowledge/heatmap

Composite module health scores on a 0-100 scale with red/yellow/green zone classification.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/heatmap?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "modules": [
    {"module": "Giulia.Knowledge.Store", "score": 82, "zone": "red", "factors": {"complexity": 0.9, "centrality": 0.8}},
    {"module": "Giulia.Tools.ReadFile", "score": 15, "zone": "green", "factors": {"complexity": 0.1, "centrality": 0.1}}
  ],
  "count": 138,
  "zones": {"red": 5, "yellow": 18, "green": 115}
}
```

---

### GET /api/knowledge/unprotected_hubs

Find hub modules with low `@spec`/`@doc` coverage. High-traffic modules that lack contracts are risky.

**Parameters (query string):**

| Param            | Required | Description                                 |
|------------------|----------|---------------------------------------------|
| `path`           | Yes      | Host-side project path                      |
| `hub_threshold`  | No       | Minimum in-degree to qualify as hub (default: 3) |
| `spec_threshold` | No       | Minimum spec coverage ratio (default: 0.5)  |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/unprotected_hubs?path=C:/Development/GitHub/Giulia&hub_threshold=5"
```

**Response:**

```json
{
  "modules": [
    {"module": "Giulia.Daemon.Helpers", "in_degree": 9, "spec_coverage": 0.2, "severity": "red"}
  ],
  "count": 3,
  "severity_counts": {"red": 1, "yellow": 2}
}
```

---

### GET /api/knowledge/struct_lifecycle

Trace struct data flow across modules: creation points, usage, and transformations.

**Parameters (query string):**

| Param    | Required | Description                         |
|----------|----------|-------------------------------------|
| `path`   | Yes      | Host-side project path              |
| `struct` | No       | Filter to a specific struct name    |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/struct_lifecycle?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "structs": [
    {
      "name": "Giulia.Core.PathSandbox",
      "created_in": ["Giulia.Core.PathSandbox"],
      "used_in": ["Giulia.Tools.ReadFile", "Giulia.Tools.WriteFile"],
      "transformed_in": []
    }
  ],
  "count": 14
}
```

---

### GET /api/knowledge/duplicates

Find semantically similar functions using embedding cosine similarity. Requires active `EmbeddingServing`.

**Parameters (query string):**

| Param       | Required | Description                                     |
|-------------|----------|-------------------------------------------------|
| `path`      | Yes      | Host-side project path                          |
| `threshold` | No       | Similarity threshold 0.0-1.0 (default: 0.85)   |
| `max`       | No       | Maximum clusters to return (default: 20)        |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/duplicates?path=C:/Development/GitHub/Giulia&threshold=0.9"
```

**Response:**

```json
{
  "clusters": [
    {
      "similarity": 0.95,
      "functions": [
        {"module": "Giulia.Daemon.Routers.Knowledge", "function": "parse_int_param/2"},
        {"module": "Giulia.Daemon.Routers.Runtime", "function": "parse_int_param/2"}
      ]
    }
  ],
  "count": 3
}
```

---

### GET /api/knowledge/audit

Unified audit combining all four Principal Consultant analyses: unprotected hubs, struct lifecycle, semantic duplicates, and behaviour integrity.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/knowledge/audit?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "audit_version": "build_90",
  "unprotected_hubs": {"modules": [...], "count": 3},
  "struct_lifecycle": {"structs": [...], "count": 14},
  "semantic_duplicates": {"clusters": [...], "count": 3},
  "behaviour_integrity": {"status": "consistent", "fractures": []}
}
```

---

## Intelligence

Higher-order analysis: briefings, preflight checks, architect briefs, and plan validation. Managed by `Giulia.Daemon.Routers.Intelligence`.

Note: These endpoints are forwarded from multiple path prefixes (`/api/intelligence`, `/api/briefing`, `/api/brief`, `/api/plan`) due to historical path conventions.

### GET /api/intelligence/briefing

Surgical briefing for a prompt. Combines semantic search with graph pre-processing to identify relevant modules and context.

**Parameters (query string):**

| Param    | Required | Description                       |
|----------|----------|-----------------------------------|
| `path`   | Yes      | Host-side project path            |
| `prompt` | Yes      | The prompt to build context for (alias: `q`) |

**Example:**

```bash
curl "http://localhost:4000/api/intelligence/briefing?path=C:/Development/GitHub/Giulia&prompt=add%20a%20new%20tool"
```

**Response:**

```json
{
  "status": "ok",
  "briefing": {
    "relevant_modules": ["Giulia.Tools.Registry", "Giulia.Tools.ReadFile"],
    "context": "..."
  }
}
```

---

### POST /api/briefing/preflight

Preflight contract checklist. Returns 6 contract sections per relevant module plus `suggested_tools` ranked by semantic similarity to the prompt.

**Parameters (JSON body):**

| Field   | Required | Description                                |
|---------|----------|--------------------------------------------|
| `prompt`| Yes      | The task description                       |
| `path`  | Yes      | Host-side project path                     |
| `top_k` | No       | Number of modules to analyze (default: 5)  |
| `depth` | No       | Graph traversal depth (default: 2)         |

**Example:**

```bash
curl -X POST http://localhost:4000/api/briefing/preflight \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Add caching to the knowledge store", "path": "C:/Development/GitHub/Giulia", "top_k": 3}'
```

**Response:**

```json
{
  "modules": [
    {
      "module": "Giulia.Knowledge.Store",
      "contracts": {
        "public_api": ["stats/1", "dependents/2"],
        "specs": ["stats/1 :: map()"],
        "behaviours": [],
        "callbacks": [],
        "struct": null,
        "dependents": ["Giulia.Daemon.Routers.Knowledge"]
      }
    }
  ],
  "suggested_tools": [
    {"endpoint": "GET /api/knowledge/stats", "intent": "Get Knowledge Graph statistics", "score": 0.87}
  ],
  "module_count": 3
}
```

---

### GET /api/brief/architect

Single-call session briefing. Returns project topology, health heatmap, constitution summary, and runtime info. Recommended as the first call in any session.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/brief/architect?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "project": "Giulia",
  "shape": {
    "modules": 138,
    "functions": 1418,
    "edges": 1544,
    "components": 3
  },
  "heatmap_summary": {
    "red": 5,
    "yellow": 18,
    "green": 115
  },
  "top_hubs": [
    {"module": "Giulia.Knowledge.Store", "degree": 28}
  ],
  "constitution": {
    "taboos": ["Never use umbrella projects"],
    "preferred_patterns": ["Use context modules for business logic"]
  },
  "runtime": {
    "node": "worker@giulia-worker",
    "memory_mb": 256,
    "process_count": 312
  }
}
```

---

### POST /api/plan/validate

Validate a proposed plan against the Knowledge Graph. Checks for dependency violations, blast radius, and risk.

**Parameters (JSON body):**

| Field  | Required | Description                                           |
|--------|----------|-------------------------------------------------------|
| `path` | Yes      | Host-side project path                                |
| `plan` | Yes      | Plan description (string or structured list of steps) |

**Example:**

```bash
curl -X POST http://localhost:4000/api/plan/validate \
  -H "Content-Type: application/json" \
  -d '{"path": "C:/Development/GitHub/Giulia", "plan": "Rename Giulia.Daemon.Helpers to Giulia.Daemon.Utils"}'
```

**Response:**

```json
{
  "valid": false,
  "risk": "high",
  "issues": [
    "Giulia.Daemon.Helpers has 9 dependents — renaming will break all sub-routers"
  ],
  "blast_radius": 9,
  "suggestion": "Consider adding an alias instead of a full rename"
}
```

---

### GET /api/intelligence/report_rules

Get canonical report generation rules (section order, scoring formulas, formatting, and Elixir idiom rules).

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/intelligence/report_rules
```

**Response:**

```json
{
  "status": "ok",
  "rules": "# Report Generation Rules\n..."
}
```

---

## Runtime

BEAM runtime introspection endpoints. Managed by `Giulia.Daemon.Routers.Runtime`. Supports both self-introspection and remote node inspection via the optional `?node` parameter.

### GET /api/runtime/pulse

BEAM health snapshot: memory breakdown, process count, scheduler utilization, ETS table count.

**Parameters (query string):**

| Param  | Required | Description                                      |
|--------|----------|--------------------------------------------------|
| `node` | No       | Remote node name (default: self-introspection)   |

**Example:**

```bash
curl http://localhost:4000/api/runtime/pulse
```

**Response:**

```json
{
  "memory": {
    "total_mb": 256,
    "processes_mb": 45,
    "ets_mb": 38,
    "binary_mb": 12,
    "atom_mb": 1
  },
  "processes": 312,
  "schedulers": 8,
  "scheduler_utilization": 0.15,
  "ets_tables": 42,
  "run_queue": 0,
  "uptime_seconds": 3600
}
```

---

### GET /api/runtime/top_processes

Top 10 processes sorted by a given metric.

**Parameters (query string):**

| Param    | Required | Description                                               |
|----------|----------|-----------------------------------------------------------|
| `metric` | No       | One of: `reductions`, `memory`, `message_queue` (default: `reductions`) |
| `node`   | No       | Remote node name                                          |

**Example:**

```bash
curl "http://localhost:4000/api/runtime/top_processes?metric=memory"
```

**Response:**

```json
{
  "processes": [
    {"pid": "#PID<0.500.0>", "registered_name": "Giulia.Knowledge.Store", "memory": 8388608},
    {"pid": "#PID<0.501.0>", "registered_name": "Giulia.Context.Store", "memory": 4194304}
  ],
  "count": 10,
  "metric": "memory"
}
```

---

### GET /api/runtime/hot_spots

Top runtime modules fused with Knowledge Graph data. Combines process reduction counts with static analysis metrics.

**Parameters (query string):**

| Param  | Required | Description                                    |
|--------|----------|------------------------------------------------|
| `path` | No       | Host-side project path (enables graph fusion)  |
| `node` | No       | Remote node name                               |

**Example:**

```bash
curl "http://localhost:4000/api/runtime/hot_spots?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "hot_spots": [
    {
      "module": "Giulia.Knowledge.Store",
      "reductions": 15000000,
      "in_degree": 28,
      "complexity": 320,
      "zone": "red"
    }
  ],
  "count": 10
}
```

---

### GET /api/runtime/trace

Short-lived per-module function call trace. Traces all calls to the specified module for the given duration.

**Parameters (query string):**

| Param      | Required | Description                                   |
|------------|----------|-----------------------------------------------|
| `module`   | Yes      | Module name to trace                          |
| `duration` | No       | Trace duration in milliseconds (default: 5000) |
| `node`     | No       | Remote node name                              |

**Example:**

```bash
curl "http://localhost:4000/api/runtime/trace?module=Giulia.Knowledge.Store&duration=3000"
```

**Response:**

```json
{
  "module": "Giulia.Knowledge.Store",
  "duration_ms": 3000,
  "calls": [
    {"function": "stats/1", "count": 5},
    {"function": "dependents/2", "count": 2}
  ],
  "total_calls": 7
}
```

---

### GET /api/runtime/history

Last N runtime snapshots from the Collector.

**Parameters (query string):**

| Param  | Required | Description                           |
|--------|----------|---------------------------------------|
| `last` | No       | Number of snapshots (default: 20)     |
| `node` | No       | Remote node name                      |

**Example:**

```bash
curl "http://localhost:4000/api/runtime/history?last=5"
```

**Response:**

```json
{
  "snapshots": [
    {"timestamp": "2026-03-16T10:05:00Z", "memory_mb": 256, "processes": 312, "run_queue": 0}
  ],
  "count": 5
}
```

---

### GET /api/runtime/trend

Time-series for a single runtime metric.

**Parameters (query string):**

| Param    | Required | Description                                                     |
|----------|----------|-----------------------------------------------------------------|
| `metric` | No       | One of: `memory`, `processes`, `run_queue`, `ets_memory` (default: `memory`) |
| `node`   | No       | Remote node name                                                |

**Example:**

```bash
curl "http://localhost:4000/api/runtime/trend?metric=memory"
```

**Response:**

```json
{
  "metric": "memory",
  "points": [
    {"timestamp": "2026-03-16T10:00:00Z", "value": 240},
    {"timestamp": "2026-03-16T10:05:00Z", "value": 256}
  ],
  "count": 12
}
```

---

### GET /api/runtime/alerts

Active runtime warnings with duration (e.g., high memory, run queue buildup).

**Parameters (query string):**

| Param  | Required | Description          |
|--------|----------|----------------------|
| `node` | No       | Remote node name     |

**Example:**

```bash
curl http://localhost:4000/api/runtime/alerts
```

**Response:**

```json
{
  "alerts": [
    {"type": "high_memory", "threshold_mb": 512, "current_mb": 580, "duration_seconds": 120}
  ],
  "count": 1
}
```

---

### POST /api/runtime/connect

Connect to a remote BEAM node for distributed introspection. Both nodes must share the same Erlang cookie.

**Parameters (JSON body):**

| Field    | Required | Description                                          |
|----------|----------|------------------------------------------------------|
| `node`   | Yes      | Remote node name (e.g., `myapp@192.168.1.50`)       |
| `cookie` | No       | Erlang cookie (default: uses daemon's cookie)        |

**Example:**

```bash
curl -X POST http://localhost:4000/api/runtime/connect \
  -H "Content-Type: application/json" \
  -d '{"node": "myapp@192.168.1.50", "cookie": "giulia_dev"}'
```

**Response:**

```json
{
  "status": "connected",
  "node": "myapp@192.168.1.50"
}
```

---

### GET /api/runtime/monitor/status

Monitor lifecycle status: current phase, profile count, burst detection state.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/runtime/monitor/status
```

**Response:**

```json
{
  "phase": "idle",
  "profiles_count": 5,
  "burst_state": "waiting",
  "last_burst_at": "2026-03-16T10:00:00Z"
}
```

---

### GET /api/runtime/profiles

List saved performance profiles from burst analysis.

**Parameters (query string):**

| Param   | Required | Description                        |
|---------|----------|------------------------------------|
| `limit` | No       | Maximum profiles to return (default: 20) |

**Example:**

```bash
curl "http://localhost:4000/api/runtime/profiles?limit=5"
```

**Response:**

```json
{
  "profiles": [
    {
      "id": "2026-03-16T10:00:00Z",
      "timestamp": "2026-03-16T10:00:00Z",
      "duration_ms": 15000,
      "snapshot_count": 30,
      "hot_modules_count": 5,
      "bottleneck_count": 2
    }
  ],
  "count": 5
}
```

---

### GET /api/runtime/profile/latest

Most recent performance profile with full detail.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/runtime/profile/latest
```

**Response:**

```json
{
  "id": "2026-03-16T10:00:00Z",
  "duration_ms": 15000,
  "hot_modules": [
    {"module": "Giulia.Knowledge.Store", "peak_reductions": 15000000}
  ],
  "bottleneck_analysis": [
    {"module": "Giulia.AST.Processor", "reason": "high_cpu_sustained"}
  ],
  "peak_metrics": {"memory_mb": 300, "run_queue": 4}
}
```

---

### GET /api/runtime/profile/:id

Retrieve a specific performance profile by its timestamp ID.

**Parameters (path):**

| Param | Required | Description               |
|-------|----------|---------------------------|
| `id`  | Yes      | Profile timestamp ID      |

**Example:**

```bash
curl http://localhost:4000/api/runtime/profile/2026-03-16T10:00:00Z
```

**Response:** Same structure as `/api/runtime/profile/latest`.

---

### POST /api/runtime/ingest

Receive a runtime snapshot pushed by the Monitor container. Used in the dual-container (worker + monitor) architecture.

**Parameters (JSON body):**

| Field        | Required | Description                              |
|--------------|----------|------------------------------------------|
| `node`       | Yes      | Source node name                         |
| `session_id` | Yes      | Observation session identifier           |
| `timestamp`  | Yes      | Snapshot timestamp                       |
| `metrics`    | Yes      | Runtime metrics object                   |

**Example:**

```bash
curl -X POST http://localhost:4000/api/runtime/ingest \
  -H "Content-Type: application/json" \
  -d '{"node": "myapp@host", "session_id": "abc123", "timestamp": "2026-03-16T10:00:00Z", "metrics": {"memory_mb": 256, "processes": 312}}'
```

**Response:**

```json
{
  "status": "ok",
  "session_id": "abc123",
  "snapshot_count": 15
}
```

---

### POST /api/runtime/ingest/finalize

Finalize an observation session. Produces a fused profile combining runtime snapshots with static analysis.

**Parameters (JSON body):**

| Field        | Required | Description                    |
|--------------|----------|--------------------------------|
| `session_id` | Yes      | Observation session identifier |
| `node`       | Yes      | Source node name               |

**Example:**

```bash
curl -X POST http://localhost:4000/api/runtime/ingest/finalize \
  -H "Content-Type: application/json" \
  -d '{"session_id": "abc123", "node": "myapp@host"}'
```

**Response:**

```json
{
  "status": "finalized",
  "session_id": "abc123",
  "snapshots_processed": 30,
  "duration_ms": 15000,
  "hot_modules": [...],
  "correlation": [...]
}
```

---

### GET /api/runtime/observations

List all available fused observation sessions.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/runtime/observations
```

**Response:**

```json
{
  "observations": [
    {
      "session_id": "abc123",
      "node": "myapp@host",
      "started_at": "2026-03-16T10:00:00Z",
      "stopped_at": "2026-03-16T10:15:00Z",
      "status": "finalized",
      "snapshots_processed": 30,
      "duration_ms": 900000
    }
  ],
  "count": 1
}
```

---

### GET /api/runtime/observation/:session_id

Full fused observation profile with static + runtime correlation data.

**Parameters (path):**

| Param        | Required | Description                    |
|--------------|----------|--------------------------------|
| `session_id` | Yes      | Observation session identifier |

**Example:**

```bash
curl http://localhost:4000/api/runtime/observation/abc123
```

**Response:**

```json
{
  "session_id": "abc123",
  "node": "myapp@host",
  "status": "finalized",
  "duration_ms": 900000,
  "fused_profile": {
    "hot_modules": [...],
    "bottleneck_analysis": [...],
    "peak_metrics": {...}
  }
}
```

---

## Search

Code search endpoints: text pattern matching and embedding-based semantic search. Managed by `Giulia.Daemon.Routers.Search`.

### GET /api/search

Direct text pattern search across project source files. No LLM involved.

**Parameters (query string):**

| Param     | Required | Description                         |
|-----------|----------|-------------------------------------|
| `pattern` | Yes      | Search pattern (alias: `q`)         |
| `path`    | No       | Host-side project path (default: cwd) |

**Example:**

```bash
curl "http://localhost:4000/api/search?pattern=defmodule.*Router&path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "status": "ok",
  "results": [
    {"file": "lib/giulia/daemon/routers/index.ex", "line": 1, "content": "defmodule Giulia.Daemon.Routers.Index do"}
  ]
}
```

---

### GET /api/search/semantic

Semantic search by concept using embedding cosine similarity. Requires active `EmbeddingServing`.

**Parameters (query string):**

| Param     | Required | Description                               |
|-----------|----------|-------------------------------------------|
| `concept` | Yes      | Concept to search for (alias: `q`)        |
| `path`    | Yes      | Host-side project path                    |
| `top_k`   | No       | Number of results (default: 5)            |

**Example:**

```bash
curl "http://localhost:4000/api/search/semantic?concept=file%20reading&path=C:/Development/GitHub/Giulia&top_k=3"
```

**Response:**

```json
{
  "concept": "file reading",
  "modules": [
    {"module": "Giulia.Tools.ReadFile", "score": 0.94, "moduledoc": "Sandboxed file reading"}
  ],
  "functions": [
    {"module": "Giulia.Tools.ReadFile", "function": "execute", "arity": 2, "score": 0.91, "file": "lib/giulia/tools/read_file.ex", "line": 25}
  ],
  "count": 3
}
```

---

### GET /api/search/semantic/status

Check semantic search index status (whether embeddings are loaded for a project).

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/search/semantic/status?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "available": true,
  "module_embeddings": 138,
  "function_embeddings": 626,
  "serving_loaded": true
}
```

---

## Transaction

Transactional exoskeleton endpoints for safe write operations. Managed by `Giulia.Daemon.Routers.Transaction`.

### POST /api/transaction/enable

Toggle transaction mode for a project. When enabled, file writes are staged for approval before committing.

**Parameters (JSON body):**

| Field  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl -X POST http://localhost:4000/api/transaction/enable \
  -H "Content-Type: application/json" \
  -d '{"path": "C:/Development/GitHub/Giulia"}'
```

**Response:**

```json
{
  "status": "enabled",
  "transaction_mode": true
}
```

---

### GET /api/transaction/staged

View transaction preference and staged files. Staged files exist only during active inference sessions.

**Parameters (query string):**

| Param  | Required | Description            |
|--------|----------|------------------------|
| `path` | No       | Host-side project path |

**Example:**

```bash
curl "http://localhost:4000/api/transaction/staged?path=C:/Development/GitHub/Giulia"
```

**Response:**

```json
{
  "transaction_mode": true,
  "staged_files": [],
  "count": 0,
  "note": "Staged files exist only during active inference sessions"
}
```

---

### POST /api/transaction/rollback

Reset transaction mode (disable). Reverts to direct write behavior.

**Parameters (JSON body):**

| Field  | Required | Description            |
|--------|----------|------------------------|
| `path` | Yes      | Host-side project path |

**Example:**

```bash
curl -X POST http://localhost:4000/api/transaction/rollback \
  -H "Content-Type: application/json" \
  -d '{"path": "C:/Development/GitHub/Giulia"}'
```

**Response:**

```json
{
  "status": "reset",
  "transaction_mode": false
}
```

---

## Approval

Consent gate for tool execution during inference. Managed by `Giulia.Daemon.Routers.Approval`.

### POST /api/approval/:approval_id

Respond to an approval request (approve or deny).

**Parameters:**

| Location | Param         | Required | Description                      |
|----------|---------------|----------|----------------------------------|
| Path     | `approval_id` | Yes      | Approval request identifier      |
| Body     | `approved`    | Yes      | Boolean: `true` to approve, `false` to deny |

**Example:**

```bash
curl -X POST http://localhost:4000/api/approval/abc123 \
  -H "Content-Type: application/json" \
  -d '{"approved": true}'
```

**Response:**

```json
{
  "status": "ok",
  "approval_id": "abc123",
  "approved": true
}
```

---

### GET /api/approval/:approval_id

Get details of a pending approval request.

**Parameters (path):**

| Param         | Required | Description                 |
|---------------|----------|-----------------------------|
| `approval_id` | Yes      | Approval request identifier |

**Example:**

```bash
curl http://localhost:4000/api/approval/abc123
```

**Response:**

```json
{
  "approval_id": "abc123",
  "tool": "write_file",
  "args": {"path": "lib/giulia/new_module.ex", "content": "..."},
  "created_at": "2026-03-16T10:00:00Z"
}
```

---

## Monitor

Logic Monitor dashboard and telemetry streaming. Managed by `Giulia.Daemon.Routers.Monitor`.

### GET /api/monitor

Serve the Logic Monitor HTML dashboard. Opens in a browser for real-time inference telemetry visualization.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/monitor
# Or open in browser: http://localhost:4000/api/monitor
```

**Response:** HTML page (not JSON).

---

### GET /api/monitor/stream

SSE endpoint for real-time telemetry events. Subscribe to receive OODA loop events, LLM calls, tool executions, and API requests as they happen.

**Parameters:** None.

**Example:**

```bash
curl -N http://localhost:4000/api/monitor/stream
```

**Response (SSE):**

```
event: connected
data: {"status":"ok"}

event: event
data: {"event":"ooda.step","measurements":{"duration_ms":150},"metadata":{"step":"think"},"timestamp":"2026-03-16T10:00:00Z"}
```

---

### GET /api/monitor/history

Recent telemetry events from the rolling buffer (last N events, default 50).

**Parameters (query string):**

| Param | Required | Description                          |
|-------|----------|--------------------------------------|
| `n`   | No       | Number of events to return (default: 50) |

**Example:**

```bash
curl "http://localhost:4000/api/monitor/history?n=10"
```

**Response:**

```json
{
  "events": [
    {
      "event": "ooda.step",
      "measurements": {"duration_ms": 150},
      "metadata": {"step": "think"},
      "timestamp": "2026-03-16T10:00:00Z"
    }
  ],
  "count": 10
}
```

---

### POST /api/monitor/observe/start

Start an async observation session targeting a remote BEAM node. The Monitor container will periodically push runtime snapshots to the Worker.

**Parameters (JSON body):**

| Field           | Required | Description                                           |
|-----------------|----------|-------------------------------------------------------|
| `node`          | Yes      | Target node name (e.g., `myapp@192.168.1.50`)        |
| `cookie`        | No       | Erlang cookie for authentication                      |
| `worker_url`    | No       | Worker URL for snapshot push (default: auto-detected) |
| `interval_ms`   | No       | Snapshot interval in milliseconds                     |
| `trace_modules` | No       | List of module names to trace during observation      |

**Example:**

```bash
curl -X POST http://localhost:4000/api/monitor/observe/start \
  -H "Content-Type: application/json" \
  -d '{"node": "myapp@192.168.1.50", "cookie": "giulia_dev", "interval_ms": 5000}'
```

**Response:**

```json
{
  "status": "observing",
  "session_id": "obs_abc123",
  "node": "myapp@192.168.1.50",
  "interval_ms": 5000,
  "trace_modules": []
}
```

---

### POST /api/monitor/observe/stop

Stop the active observation and trigger Worker-side finalization.

**Parameters (JSON body):**

| Field  | Required | Description                                 |
|--------|----------|---------------------------------------------|
| `node` | No       | Node name (for multi-target disambiguation) |

**Example:**

```bash
curl -X POST http://localhost:4000/api/monitor/observe/stop \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Response:**

```json
{
  "status": "stopped",
  "snapshots_pushed": 30,
  "duration_ms": 150000,
  "finalize_result": {"status": "finalized", "session_id": "obs_abc123"}
}
```

---

### GET /api/monitor/observe/status

Check whether an observation is currently running.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/monitor/observe/status
```

**Response:**

```json
{
  "status": "observing",
  "node": "myapp@192.168.1.50",
  "session_id": "obs_abc123",
  "elapsed_ms": 45000,
  "snapshots_pushed": 9
}
```

---

## Discovery

Self-describing API discovery. Aggregates `__skills__/0` from all 9 domain sub-routers at runtime. Managed by `Giulia.Daemon.Routers.Discovery`.

### GET /api/discovery/skills

List all available API skills (endpoints) with optional category filter.

**Parameters (query string):**

| Param      | Required | Description                           |
|------------|----------|---------------------------------------|
| `category` | No       | Filter by category name               |

**Example:**

```bash
curl "http://localhost:4000/api/discovery/skills?category=knowledge"
```

**Response:**

```json
{
  "skills": [
    {
      "intent": "Get Knowledge Graph statistics (vertices, edges, components, hubs)",
      "endpoint": "GET /api/knowledge/stats",
      "params": {"path": "required"},
      "returns": "JSON graph stats with top hub modules",
      "category": "knowledge"
    }
  ],
  "count": 23
}
```

---

### GET /api/discovery/categories

List all skill categories with endpoint counts.

**Parameters:** None.

**Example:**

```bash
curl http://localhost:4000/api/discovery/categories
```

**Response:**

```json
{
  "categories": [
    {"category": "approval", "count": 2},
    {"category": "discovery", "count": 3},
    {"category": "index", "count": 9},
    {"category": "intelligence", "count": 5},
    {"category": "knowledge", "count": 23},
    {"category": "monitor", "count": 6},
    {"category": "runtime", "count": 16},
    {"category": "search", "count": 3},
    {"category": "transaction", "count": 3}
  ],
  "total": 9
}
```

---

### GET /api/discovery/search

Search skills by keyword. Case-insensitive substring match on the `intent` field.

**Parameters (query string):**

| Param | Required | Description       |
|-------|----------|-------------------|
| `q`   | Yes      | Search keyword    |

**Example:**

```bash
curl "http://localhost:4000/api/discovery/search?q=dead%20code"
```

**Response:**

```json
{
  "skills": [
    {
      "intent": "Detect dead code (functions defined but never called)",
      "endpoint": "GET /api/knowledge/dead_code",
      "params": {"path": "required"},
      "returns": "JSON list of unused functions",
      "category": "knowledge"
    }
  ],
  "count": 1,
  "query": "dead code"
}
```

---

## Error Responses

All endpoints return errors in a consistent format:

```json
{
  "error": "Description of what went wrong"
}
```

Common HTTP status codes:

| Code | Meaning                                                    |
|------|------------------------------------------------------------|
| 200  | Success                                                    |
| 400  | Bad request (missing required parameters)                  |
| 404  | Resource not found (module not in graph, profile missing)  |
| 422  | Unprocessable entity (valid request but processing failed) |
| 500  | Internal server error                                      |
| 503  | Service unavailable (EmbeddingServing not loaded)          |

---

## Quick Reference

| Category     | Count | Prefix               |
|--------------|-------|-----------------------|
| Core         | 10    | `/health`, `/api/*`   |
| Index        | 9     | `/api/index/*`        |
| Knowledge    | 23    | `/api/knowledge/*`    |
| Intelligence | 5     | `/api/intelligence/*`, `/api/briefing/*`, `/api/brief/*`, `/api/plan/*` |
| Runtime      | 16    | `/api/runtime/*`      |
| Search       | 3     | `/api/search/*`       |
| Transaction  | 3     | `/api/transaction/*`  |
| Approval     | 2     | `/api/approval/*`     |
| Monitor      | 6     | `/api/monitor/*`      |
| Discovery    | 3     | `/api/discovery/*`    |
| **Total**    | **80**|                       |

Note: The 80 total includes 10 core endpoints defined in the Endpoint module. The 9 sub-routers contribute 70 self-describing skills via the `@skill` decorator pattern, queryable at runtime through the Discovery API.
