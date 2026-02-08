# Giulia Code Analysis Tools

Complete reference for Giulia's HTTP API endpoints. All endpoints return JSON.

**Base URL**: `http://localhost:4000`

---

## Health & Status

### `GET /health`

System health check.

```json
{"status": "ok", "node": "nonode@nohost", "version": "v0.1.0.65"}
```

### `GET /api/status`

Daemon uptime and active projects.

```json
{"node": "...", "started_at": "...", "uptime_seconds": 3600, "active_projects": [...]}
```

### `POST /api/ping`

Check if a project path is initialized.

**Body**: `{"path": "C:/Development/GitHub/MyProject"}`

```json
{"status": "ok", "path": "..."}
```

Status is `"ok"`, `"needs_init"`, or `"error"`.

---

## Index (AST / ETS)

All index endpoints require `?path=<project_path>`.

### `GET /api/index/modules?path=P`

All modules found in the project.

```json
{
  "modules": [{"name": "MyApp.Router", "file": "/projects/...", "line": 1}, ...],
  "count": 42
}
```

### `GET /api/index/functions?path=P`

All functions across the project. Optionally filter by module.

| Param | Required | Description |
|-------|----------|-------------|
| `path` | yes | Project path |
| `module` | no | Filter to a single module |

```json
{
  "functions": [
    {"module": "MyApp.Router", "name": "call", "arity": 2, "type": "def", "line": 15}
  ],
  "count": 310,
  "module": "MyApp.Router"
}
```

### `GET /api/index/module_details?path=P&module=M`

Full API surface of a single module: functions, types, specs, callbacks, struct fields.

```json
{
  "module": "MyApp.Accounts",
  "details": {
    "file": "/projects/.../accounts.ex",
    "moduledoc": "...",
    "functions": [...],
    "types": [...],
    "specs": [...],
    "callbacks": [...],
    "struct": [...]
  }
}
```

### `GET /api/index/summary?path=P`

High-level project shape.

```json
{
  "summary": {
    "modules_count": 42,
    "functions_count": 310,
    "types": 12,
    "specs": 85,
    "structs": 5,
    "callbacks": 8,
    "dead_code_candidates": 3
  }
}
```

### `GET /api/index/status`

Indexer state (global, not per-project).

```json
{"status": "idle", "file_count": 54, "last_scan_time": "2025-06-01T12:00:00Z"}
```

### `POST /api/index/scan`

Trigger a background AST re-scan. Call this after editing files directly.

**Body**: `{"path": "C:/Development/GitHub/MyProject"}`

```json
{"status": "scanning", "path": "..."}
```

---

## Knowledge Graph

All knowledge endpoints require `?path=<project_path>`.

### `GET /api/knowledge/stats?path=P`

Graph topology overview: vertices, edges, connected components, top hubs.

```json
{
  "vertices": 867,
  "edges": 182,
  "components": 3,
  "hubs": [{"module": "MyApp.Registry", "degree": 22}, ...],
  "cyclomatic_complexity": 15
}
```

### `GET /api/knowledge/dependents?path=P&module=M`

Who depends on module M (downstream blast radius).

```json
{"module": "MyApp.Registry", "dependents": ["MyApp.Tools.ReadFile", ...], "count": 22}
```

### `GET /api/knowledge/dependencies?path=P&module=M`

What module M depends on (upstream).

```json
{"module": "MyApp.Client", "dependencies": ["MyApp.Core.PathMapper", ...], "count": 5}
```

### `GET /api/knowledge/centrality?path=P&module=M`

Hub score. High in-degree = many dependents = dangerous to modify.

```json
{"module": "MyApp.Registry", "in_degree": 22, "out_degree": 3, "dependents": [...]}
```

### `GET /api/knowledge/impact?path=P&module=M&depth=N`

Full upstream + downstream impact map at depth N (default: 2).

```json
{
  "module": "MyApp.Registry",
  "depth": 2,
  "upstream": [{"module": "MyApp.Tools.Base", "depth": 1}, ...],
  "downstream": [{"module": "MyApp.Client", "depth": 1}, ...],
  "function_edges": [{"function": "execute/3", "calls": [...]}, ...]
}
```

### `GET /api/knowledge/path?path=P&from=A&to=B`

Shortest dependency path between two modules.

```json
{"from": "MyApp.Client", "to": "MyApp.Registry", "path": ["MyApp.Client", "MyApp.Daemon", "MyApp.Registry"], "hops": 2}
```

Returns `"path": null` if no path exists.

---

## Code Health

All code health endpoints require `?path=<project_path>`.

### `GET /api/knowledge/dead_code?path=P`

Functions that are defined but never called. Respects `@dead_code_ignore true` module attribute, OTP/framework callbacks, and behaviour implementations.

```json
{
  "dead_functions": [
    {"module": "MyApp.Legacy", "name": "old_handler", "arity": 2, "type": "def", "file": "...", "line": 45}
  ],
  "total": 1
}
```

### `GET /api/knowledge/cycles?path=P`

Circular dependency chains in the module graph.

```json
{"cycles": [["MyApp.A", "MyApp.B", "MyApp.A"], ...], "count": 1}
```

### `GET /api/knowledge/god_modules?path=P`

Modules that do too much: high function count, high centrality, high complexity.

```json
{
  "god_modules": [
    {"module": "MyApp.Orchestrator", "function_count": 85, "centrality": 12, "cyclomatic_complexity": 30, "score": 127}
  ],
  "count": 1
}
```

### `GET /api/knowledge/orphan_specs?path=P`

`@spec` annotations with no matching function implementation.

```json
{"orphan_specs": [{"module": "MyApp.Old", "name": "removed_fn", "arity": 1, "line": 20}], "total": 1}
```

### `GET /api/knowledge/fan_in_out?path=P`

Modules with imbalanced fan-in vs fan-out (dependency smell).

```json
{
  "imbalanced": [
    {"module": "MyApp.Utils", "fan_in": 25, "fan_out": 1, "ratio": 25.0}
  ],
  "count": 1
}
```

### `GET /api/knowledge/coupling?path=P`

Pairs of modules with high mutual coupling.

```json
{
  "high_coupling": [
    {"module_a": "MyApp.A", "module_b": "MyApp.B", "function_call_count": 15, "score": 0.85}
  ],
  "count": 1
}
```

### `GET /api/knowledge/api_surface?path=P`

Public vs private function ratio per module. High public ratio = poor encapsulation.

```json
{
  "api_analysis": [
    {"module": "MyApp.Helpers", "public_functions": 20, "private_functions": 2, "public_ratio": 0.91, "score": 0.91}
  ],
  "count": 1
}
```

### `GET /api/knowledge/change_risk?path=P`

Composite risk score per module. Combines centrality, dead code, cycles, god module score.

```json
{
  "change_risk_scores": [
    {"module": "MyApp.Registry", "centrality": 22, "dead_code": 0, "cycles": 0, "god_module": 85, "change_risk_score": 107}
  ],
  "count": 1
}
```

### `GET /api/knowledge/integrity?path=P`

Behaviour contract integrity. Finds implementers that are missing required callback functions.

```json
{
  "status": "consistent",
  "fractures": []
}
```

When fractured:

```json
{
  "status": "fractured",
  "fractures": [
    {"behaviour": "MyApp.Provider", "implementers": [{"name": "MyApp.Provider.Ollama", "missing": ["stream/2"]}]}
  ]
}
```

---

## Search

### `GET /api/search?pattern=PATTERN&path=P`

State-first code search. Reads the file list from ETS (populated by the Indexer), never touches the filesystem to discover files. Disk I/O only happens when reading file contents for matching. Searches are scoped to first-party source code only — no `deps/`, `_build/`, or other artifacts.

**Requires a prior scan** (`POST /api/index/scan`) to populate the file registry.

| Param | Required | Description |
|-------|----------|-------------|
| `pattern` or `q` | yes | Text or regex pattern to search for |
| `path` | yes | Project path |

**Performance**: Parallel `Task.async_stream` across all cores with compiled `:binary.match` for literal patterns, `Regex` for regex patterns. Typical response: **40-200ms** (vs 19-23s before build 69).

**How it works**:
1. File list comes from `Store.get_project_files/1` (ETS lookup, 0 I/O)
2. Pattern is compiled once (`Regex.compile/2` or `:binary.match`)
3. Files are searched in parallel with early termination at `max_results`

```json
{
  "status": "ok",
  "results": "lib/my_app/accounts.ex:12:   defstruct name: nil, email: nil\nlib/my_app/repo.ex:5:   defstruct [...]"
}
```

---

## Inference & Agent

### `POST /api/command`

Send a command or natural language message to Giulia's OODA inference loop.

**Body**: `{"command": "/status", "path": "..."}` or `{"message": "explain this module", "path": "..."}`

### `POST /api/command/stream`

Same as `/api/command` but returns Server-Sent Events for real-time OODA loop visibility.

**Body**: `{"message": "refactor this function", "path": "..."}`

**Events**: `start`, `step` (tool calls/results), `complete`

### `GET /api/agent/last_trace`

Last inference trace — full OODA loop steps for debugging.

```json
{"trace": {"steps": [...], "tool_calls": [...], "result": "..."}}
```

---

## Transaction (Atomic Changes)

### `POST /api/transaction/enable`

Toggle transaction mode. When enabled, write operations are staged in memory instead of flushed to disk.

**Body**: `{"path": "..."}`

```json
{"status": "enabled", "transaction_mode": true}
```

### `GET /api/transaction/staged?path=P`

View currently staged changes.

```json
{"transaction_mode": true, "staged_files": ["lib/my_app/router.ex"], "count": 1}
```

### `POST /api/transaction/rollback`

Discard all staged changes and disable transaction mode.

**Body**: `{"path": "..."}`

```json
{"status": "reset", "transaction_mode": false}
```

---

## Approval Gate

### `GET /api/approvals`

List pending approval requests (for dangerous tool calls on hub modules).

```json
{
  "pending": [
    {"approval_id": "abc123", "tool": "write_file", "reason": "Hub module (centrality: 22)", "context": {...}}
  ],
  "count": 1
}
```

### `GET /api/approval/:id`

Get details of a specific pending approval.

### `POST /api/approval/:id`

Approve or deny a pending tool call.

**Body**: `{"approved": true}` or `{"approved": false}`

---

## Project Init

### `POST /api/init`

Initialize a new project context. Scans for GIULIA.md constitution.

**Body**: `{"path": "C:/Development/GitHub/MyProject", "opts": {}}`

```json
{"status": "initialized", "path": "..."}
```

### `GET /api/projects`

List all active project contexts.

```json
{"projects": ["C:/Development/GitHub/ProjectA", "C:/Development/GitHub/ProjectB"]}
```

---

## Debug

### `GET /api/debug/paths`

Show path mapping configuration (host ↔ container translation).

```json
{"in_container": true, "mappings": [{"host": "C:/Development/GitHub", "container": "/projects"}]}
```

---

## Module Attributes for Dead Code

### `@dead_code_ignore true`

Add this attribute to any module to exclude all its functions from dead code detection. Useful for IEx helpers, telemetry modules, and other entry points that are intentionally never called from code.

```elixir
defmodule MyApp.IExHelpers do
  @dead_code_ignore true

  def reload_config, do: ...
  def clear_cache, do: ...
end
```
