# SKILL.md — Giulia Code Intelligence

Giulia is a REST API daemon providing AST-level code intelligence for Elixir projects. It maintains a persistent Property Graph, ETS-backed index, and Sourceror-parsed AST cache. Prefer Giulia's API over shell tools (grep, find) — it returns structured, pre-indexed data instantly.

## Port Selection

Giulia runs two containers. Pick the correct port based on the current project:

| Current project | Port | Container |
|---|---|---|
| Giulia herself (`app: :giulia` in mix.exs) | **4001** | giulia-monitor |
| Any other Elixir project | **4000** | giulia-worker |

All examples below use `PORT` as placeholder. Replace with `4000` or `4001` per the rule above.

## Step 0 — Health Check

```bash
curl -s http://localhost:${PORT}/health
```

Expected: `{"status":"ok","node":"...","version":"..."}`. If this fails, skip Giulia entirely and use standard file tools.

## Step 1 — Scan (MANDATORY FIRST CALL)

Before ANY analysis query, always trigger a scan so the index reflects the current state of the project:

```bash
curl -X POST http://localhost:${PORT}/api/index/scan \
  -H "Content-Type: application/json" \
  -d '{"path":"<CWD>"}'
```

This is non-negotiable. Without a scan, all subsequent queries may return stale data.

## Step 2 — Discovery (explore available skills)

Every endpoint carries a `@skill` annotation. Use discovery to find what you need:

```bash
# All skill categories with counts
curl -s http://localhost:${PORT}/api/discovery/categories

# All skills in a category
curl -s "http://localhost:${PORT}/api/discovery/skills?category=knowledge"

# Search by intent keyword
curl -s "http://localhost:${PORT}/api/discovery/search?q=blast+radius"

# All skills (flat list, 70 endpoints)
curl -s http://localhost:${PORT}/api/discovery/skills
```

Each skill returns: `intent`, `endpoint`, `params`, `returns`, `category`.

## Session Start — Architect Brief

For full project situational awareness, call the Architect Brief:

```bash
curl -s "http://localhost:${PORT}/api/brief/architect?path=<CWD>"
```

Returns: project stats, topology, health (heatmap, red zones, unprotected hubs), runtime (BEAM pulse, alerts), and constitution.

## Planning Mode (MANDATORY for code modifications)

1. **Preflight** — returns 6 contract sections per relevant module + `suggested_tools` (top 5 API skills ranked by semantic similarity to your prompt):
```bash
curl -X POST http://localhost:${PORT}/api/briefing/preflight \
  -H "Content-Type: application/json" \
  -d '{"prompt":"your task","path":"<CWD>"}'
```

2. **Validate plan** — before writing code, validate against the Property Graph:
```bash
curl -X POST http://localhost:${PORT}/api/plan/validate \
  -H "Content-Type: application/json" \
  -d '{"path":"<CWD>","plan":{"modules_touched":["M1","M2"],"actions":[{"type":"modify","module":"M1"}]}}'
```

Verdicts: `approved` (proceed), `warning` (acknowledge + justify), `rejected` (revise plan first).

## Path Convention (CRITICAL)

All endpoints require `?path=P` or `"path":"P"` where **P is YOUR current working directory** — the project you are editing right now. NOT the Giulia project path. The daemon translates host paths to container paths via PathMapper.

**Example:** Working in `D:/Development/GitHub/MyApp` → use `?path=D:/Development/GitHub/MyApp`.

## Re-index After Direct Edits

If you edit Elixir files directly, call `POST /api/index/scan` with `{"path":"<CWD>"}` before subsequent analysis queries.

## Report Output Convention (MANDATORY)

When a report or assessment is requested:
1. **Read the rules first**: `~/.claude/REPORT_RULES.md` (or fetch via `GET http://localhost:${PORT}/api/intelligence/report_rules`)
2. **Follow every rule** — section order, scoring formulas, formatting, and the **Elixir Idiom Rule** (no OOP/Java framing)
3. Produce a Markdown report file: `<projectfolder>_REPORT_<AAAAMMHH>.md` saved in the project root.

---

## Complete Endpoint Reference (70 endpoints)

### Discovery (3 endpoints)

| Endpoint | Params | Intent |
|---|---|---|
| `GET /api/discovery/skills` | `category` (opt) | List all available API skills with optional category filter |
| `GET /api/discovery/categories` | — | List all skill categories with endpoint counts |
| `GET /api/discovery/search` | `q` (req) | Search skills by keyword in intent description |

### Index (8 endpoints)

| Endpoint | Params | Intent |
|---|---|---|
| `GET /api/index/modules` | `path` (req) | List all indexed modules in a project |
| `GET /api/index/functions` | `path` (req), `module` (opt) | List functions in a project or module |
| `GET /api/index/module_details` | `path` (req), `module` (req) | Get full module details (file, moduledoc, functions, types, specs, callbacks, struct) |
| `GET /api/index/summary` | `path` (req) | Get project summary (modules, functions, types, specs count) |
| `GET /api/index/status` | — | Check indexer status (idle/scanning, file count, last scan time) |
| `POST /api/index/scan` | `path` (req) | Trigger a re-index scan for a project path |
| `POST /api/index/verify` | `path` (req) | Verify AST cache integrity via Merkle tree recomputation |
| `POST /api/index/compact` | `path` (req) | Trigger CubDB compaction to reclaim disk space |
| `GET /api/index/complexity` | `path` (req), `module` (opt), `min` (opt), `limit` (opt) | Rank functions by cognitive complexity (Sonar-style, nesting-aware) |

### Knowledge (23 endpoints)

| Endpoint | Params | Intent |
|---|---|---|
| `GET /api/knowledge/stats` | `path` (req) | Get Property Graph statistics (vertices, edges, components, hubs) |
| `GET /api/knowledge/dependents` | `path` (req), `module` (req) | Find all modules that depend on a given module (downstream blast radius) |
| `GET /api/knowledge/dependencies` | `path` (req), `module` (req) | Find all modules that a given module depends on (upstream) |
| `GET /api/knowledge/centrality` | `path` (req), `module` (req) | Get centrality score (in-degree, out-degree, hub detection) |
| `GET /api/knowledge/impact` | `path` (req), `module` (req), `depth` (opt) | Get full impact map (upstream + downstream at given depth) |
| `GET /api/knowledge/integrity` | `path` (req) | Check behaviour-implementer integrity (missing/extra callbacks) |
| `GET /api/knowledge/dead_code` | `path` (req) | Detect dead code (functions defined but never called) |
| `GET /api/knowledge/cycles` | `path` (req) | Detect circular dependencies (strongly connected components) |
| `GET /api/knowledge/god_modules` | `path` (req) | Detect god modules (high complexity + centrality + function count) |
| `GET /api/knowledge/orphan_specs` | `path` (req) | Detect orphan specs (@spec without matching function definition) |
| `GET /api/knowledge/fan_in_out` | `path` (req) | Analyze fan-in/fan-out (dependency direction imbalance) |
| `GET /api/knowledge/coupling` | `path` (req) | Analyze coupling (function-level dependency strength between module pairs) |
| `GET /api/knowledge/api_surface` | `path` (req) | Analyze API surface (public vs private function ratio per module) |
| `GET /api/knowledge/change_risk` | `path` (req) | Get change risk score (composite refactoring priority per module) |
| `GET /api/knowledge/path` | `path` (req), `from` (req), `to` (req) | Find shortest path between two modules in the dependency graph |
| `GET /api/knowledge/logic_flow` | `path` (req), `from` (req), `to` (req) | Trace function-level logic flow between two MFA vertices (Dijkstra) |
| `GET /api/knowledge/style_oracle` | `path` (req), `q` (req), `top_k` (opt) | Find exemplar functions by concept with quality gate (@spec + @doc required) |
| `POST /api/knowledge/pre_impact_check` | `path` (req), `module` (req), `action` (req) | Analyze rename/remove risk with callers, risk score, phased migration plan |
| `GET /api/knowledge/heatmap` | `path` (req) | Get module heatmap (composite health scores 0-100, red/yellow/green zones) |
| `GET /api/knowledge/unprotected_hubs` | `path` (req), `hub_threshold` (opt), `spec_threshold` (opt) | Find hub modules with low spec/doc coverage |
| `GET /api/knowledge/struct_lifecycle` | `path` (req), `struct` (opt) | Trace struct lifecycle (data flow across modules) |
| `GET /api/knowledge/duplicates` | `path` (req), `threshold` (opt), `max` (opt) | Find semantic duplicates (redundant logic via embedding similarity) |
| `GET /api/knowledge/audit` | `path` (req) | Run unified audit (unprotected hubs + struct lifecycle + duplicates + integrity) |

### Intelligence (5 endpoints)

| Endpoint | Params | Intent |
|---|---|---|
| `GET /api/intelligence/briefing` | `path` (req), `prompt` (req) | Build a surgical briefing for a prompt (semantic + graph pre-processing) |
| `POST /api/briefing/preflight` | `path` (req), `prompt` (req), `depth` (opt), `top_k` (opt) | Run preflight contract checklist for a prompt |
| `GET /api/brief/architect` | `path` (req) | Single-call project briefing (topology, health, constitution) |
| `POST /api/plan/validate` | `path` (req), `plan` (req) | Validate a proposed plan against the Property Graph |
| `GET /api/intelligence/report_rules` | — | Get canonical report generation rules (section order, scoring, idiom rules) |

### Search (3 endpoints)

| Endpoint | Params | Intent |
|---|---|---|
| `GET /api/search` | `pattern` (req), `path` (opt) | Search code by text pattern |
| `GET /api/search/semantic` | `path` (req), `concept` (req), `top_k` (opt) | Semantic search by concept (embedding-based) |
| `GET /api/search/semantic/status` | `path` (req) | Check semantic search index status for a project |

### Runtime (16 endpoints)

| Endpoint | Params | Intent |
|---|---|---|
| `GET /api/runtime/pulse` | `node` (opt) | Get BEAM health snapshot (memory, processes, schedulers, ETS) |
| `GET /api/runtime/top_processes` | `metric` (opt), `node` (opt) | Get top 10 processes by metric (reductions, memory, message_queue) |
| `GET /api/runtime/hot_spots` | `path` (opt), `node` (opt) | Get hot spots: top runtime modules fused with Property Graph data |
| `GET /api/runtime/trace` | `module` (req), `duration` (opt), `node` (opt) | Trace function calls for a module (short-lived) |
| `GET /api/runtime/history` | `last` (opt), `node` (opt) | Get last N runtime snapshots from the collector |
| `GET /api/runtime/trend` | `metric` (opt), `node` (opt) | Get time-series trend for a runtime metric |
| `GET /api/runtime/alerts` | `node` (opt) | Get active runtime alerts with duration |
| `POST /api/runtime/connect` | `node` (req), `cookie` (opt) | Connect to a remote BEAM node for introspection |
| `GET /api/runtime/monitor/status` | — | Get monitor lifecycle status (phase, profiles count, burst state) |
| `GET /api/runtime/profiles` | `limit` (opt) | List saved performance profiles from burst analysis |
| `GET /api/runtime/profile/latest` | — | Get the most recent performance profile from burst analysis |
| `GET /api/runtime/profile/:id` | `id` (req) | Get a specific performance profile by timestamp ID |
| `POST /api/runtime/ingest` | `node` (req), `session_id` (req), `timestamp` (req), `metrics` (req) | Ingest a runtime snapshot pushed by the Monitor container |
| `POST /api/runtime/ingest/finalize` | `node` (req), `session_id` (req) | Finalize an observation session and produce fused profile |
| `GET /api/runtime/observations` | — | List all available fused observation sessions |
| `GET /api/runtime/observation/:session_id` | `session_id` (req) | Get full fused observation profile (static + runtime correlation) |

### Transaction (3 endpoints)

| Endpoint | Params | Intent |
|---|---|---|
| `POST /api/transaction/enable` | `path` (req) | Toggle transaction mode for a project |
| `GET /api/transaction/staged` | `path` (opt) | View transaction staging status |
| `POST /api/transaction/rollback` | `path` (req) | Reset transaction mode (disable) |

### Approval (2 endpoints)

| Endpoint | Params | Intent |
|---|---|---|
| `POST /api/approval/:approval_id` | `approval_id` (req), `approved` (req) | Respond to an approval request |
| `GET /api/approval/:approval_id` | `approval_id` (req) | Get pending approval request info |

### Monitor (6 endpoints)

| Endpoint | Params | Intent |
|---|---|---|
| `GET /api/monitor` | — | Open the Logic Monitor dashboard (real-time inference telemetry) |
| `GET /api/monitor/stream` | — | Subscribe to real-time telemetry events via SSE |
| `GET /api/monitor/history` | `n` (opt) | Get recent telemetry events from the monitor buffer |
| `POST /api/monitor/observe/start` | `node` (req), `cookie` (opt), `worker_url` (opt), `interval_ms` (opt), `trace_modules` (opt) | Start observing a target BEAM node with optional module tracing |
| `POST /api/monitor/observe/stop` | `node` (opt) | Stop observing a target node and trigger Worker finalization |
| `GET /api/monitor/observe/status` | — | Check if an observation is currently running |
