# SKILL.md — Giulia Code Intelligence

## What is Giulia?

Giulia is a REST API daemon (port 4000) that provides AST-level code intelligence for Elixir projects. It maintains a persistent Knowledge Graph, ETS-backed module/function index, and Sourceror-parsed AST cache across sessions. Prefer Giulia's API over shell tools (grep, find, cat) when the daemon is available — it returns structured, pre-indexed data instantly.

**Architecture (Build 94):** Routes are split into 7 domain sub-routers (`Giulia.Daemon.Routers.*`) forwarded from the main Endpoint. Each route carries a `@skill` annotation with intent, params, returns, and category. Every sub-router exposes `__skills__/0` for programmatic discovery. External API paths are unchanged.

## Detection

Before using any Giulia endpoint, verify the daemon is running:

```
curl -s http://localhost:4000/health
```

Expected: `{"status":"ok","node":"...","version":"..."}`.
If this fails, fall back to standard file tools. Do not retry.

## Session Start (MANDATORY)

Before any work, always call the Architect Brief to get full project situational awareness:

```bash
curl -s "http://localhost:4000/api/brief/architect?path=<CWD>"
```

This single call returns: project stats (files, modules, functions, specs), topology (vertices, edges, hubs, cycles, god modules), health (heatmap summary, red zones, unprotected hubs, behaviour integrity), runtime (BEAM pulse, alerts, hot spots with Knowledge Graph fusion), and constitution (GIULIA.md tech stack + taboos). Zero manual prompting — start every session with this.

## Tool Categories

### 0. Daemon Operations

Lifecycle, status, and project management endpoints.

| Intent | Endpoint | Returns |
|--------|----------|---------|
| Health check | `GET /health` | `{"status":"ok","node":"...","version":"v0.1.0.94"}` — confirms daemon is running |
| Daemon status | `GET /api/status` | Node name, started_at, uptime, active project count |
| Ping project | `POST /api/ping` | Check if a project is initialized without triggering inference. Body: `{"path":"P"}`. Returns `ok`, `needs_init`, or `error` |
| List active projects | `GET /api/projects` | All projects currently loaded in the daemon |
| Initialize project | `POST /api/init` | Load a project into the daemon. Body: `{"path":"P"}` — creates ProjectContext, scans GIULIA.md |
| Debug path mappings | `GET /api/debug/paths` | Shows host↔container path translations and `in_container` flag |

### 1. Understanding Code

Use these to inspect modules, functions, types, and dependencies before making changes.

| Intent | Endpoint | Returns |
|--------|----------|---------|
| Everything about a module | `GET /api/index/module_details?path=P&module=X` | File path, moduledoc, public/private functions, types, specs, callbacks, struct fields — the single most useful call before modifying anything |
| List all modules | `GET /api/index/modules?path=P` | All indexed module names with file paths |
| Functions in a module | `GET /api/index/functions?path=P&module=X` | Name, arity, line number, type (def/defp) |
| Project shape | `GET /api/index/summary?path=P` | Module count, function count, types, specs, callbacks |
| Search code patterns | `GET /api/search?pattern=X&path=Y` | Regex search scoped to project (sandboxed) |
| What X depends on | `GET /api/knowledge/dependencies?path=P&module=X` | Upstream dependencies |
| Index status | `GET /api/index/status?path=P` | Scanning state, file count, last scan time |

### 2. Analyzing Impact

Use these BEFORE modifying any shared module. They reveal the blast radius.

| Intent | Endpoint | Returns |
|--------|----------|---------|
| Full impact map | `GET /api/knowledge/impact?path=P&module=X&depth=N` | Upstream + downstream modules at depth N |
| Who depends on X | `GET /api/knowledge/dependents?path=P&module=X` | All downstream consumers (blast radius) |
| Hub score | `GET /api/knowledge/centrality?path=P&module=X` | In-degree, out-degree — high = dangerous to modify |
| Dependency path | `GET /api/knowledge/path?path=P&from=A&to=B` | Shortest path between two modules |
| Graph overview | `GET /api/knowledge/stats?path=P` | Vertices, edges, components, top hubs |
| Behaviour integrity | `GET /api/knowledge/integrity?path=P` | Checks all behaviour-implementer contracts — enriched fractures with `missing` (real), `injected` (MacroMap), `optional_omitted` (legal), `heuristic_injected` (ghost-detected). Only `missing` triggers fracture status |
| Dead code | `GET /api/knowledge/dead_code?path=P` | Functions defined but never called anywhere — excludes OTP callbacks, behaviour implementations, framework entry points |
| Circular dependencies | `GET /api/knowledge/cycles?path=P` | Strongly connected components in the module dependency graph — modules that depend on each other in a cycle |
| God modules | `GET /api/knowledge/god_modules?path=P` | Top 20 modules ranked by weighted score: function count + complexity + centrality — refactoring targets |
| Orphan specs | `GET /api/knowledge/orphan_specs?path=P` | @spec declarations where no matching function definition exists (name/arity mismatch) |
| Fan-in / fan-out | `GET /api/knowledge/fan_in_out?path=P` | Modules ranked by incoming + outgoing dependency count — high fan-out = knows too much, high fan-in = too many dependents |
| Coupling score | `GET /api/knowledge/coupling?path=P` | Top 50 module pairs ranked by how many function calls flow between them — tight coupling quantified |
| API surface | `GET /api/knowledge/api_surface?path=P` | Public vs private function ratio per module — high ratio = poor encapsulation |
| Change risk | `GET /api/knowledge/change_risk?path=P` | Composite score: centrality + complexity + fan-in/out + coupling + API surface — "refactor this first" prioritized list |
| **Logic flow** | `GET /api/knowledge/logic_flow?path=P&from=MFA&to=MFA` | Dijkstra path between two function MFA vertices (e.g. `Mod.func/2`) — traces data flow through function-call edges |
| **Style oracle** | `GET /api/knowledge/style_oracle?path=P&q=Q&top_k=N` | Exemplar functions matching concept Q, quality-gated (both @spec and @doc required) — includes source code, spec, doc |
| **Pre-impact check** | `POST /api/knowledge/pre_impact_check` | Risk analysis for rename/remove operations — callers, risk score, phased migration plan, hub warnings. Body: `{"path":"P","module":"M","action":"rename_function\|remove_function\|rename_module","target":"func/arity","new_name":"new"}` |
| **Heatmap** | `GET /api/knowledge/heatmap?path=P` | All modules scored 0-100 by composite health (centrality 30%, complexity 25%, test coverage 25%, coupling 20%) — zones: red ≥60, yellow ≥30, green <30 |
| **Unprotected hubs** | `GET /api/knowledge/unprotected_hubs?path=P&hub_threshold=3&spec_threshold=0.5` | Hub modules (in-degree ≥ threshold) with low spec/doc coverage — severity: red (<50% specs), yellow (<80% specs). Merges centrality with type safety gaps |
| **Struct lifecycle** | `GET /api/knowledge/struct_lifecycle?path=P&struct=Module.Name` | Data flow tracing per struct: which modules create/consume it, logic leaks (non-defining modules that use the struct). Optional `struct` filter |
| **Semantic duplicates** | `GET /api/knowledge/duplicates?path=P&threshold=0.85&max=20` | Clusters of semantically similar functions (cosine similarity ≥ threshold on Bumblebee embeddings). Returns connected components with avg similarity. Requires EmbeddingServing |
| **Unified audit** | `GET /api/knowledge/audit?path=P` | Combines all 4 Principal Consultant features: unprotected hubs + struct lifecycle + semantic duplicates + behaviour integrity (enriched with optional/heuristic fields). Single call for comprehensive project health report |

### 3. Intelligence (Pre-Processing Layers)

Giulia's intelligence layer runs **before** the LLM. It combines semantic search (Bumblebee embeddings) with Knowledge Graph enrichment to produce structured context automatically.

| Intent | Endpoint | Returns |
|--------|----------|---------|
| **Preflight Contract Checklist** | `POST /api/briefing/preflight` | Structured JSON: 6 contract sections per module (behaviour, type, data, macro, topology, semantic integrity) — **the single best call for planning** |
| Surgical Briefing | `GET /api/intelligence/briefing?path=P&prompt=Q` | Auto-generated context: relevant modules with hub scores, dependents, key functions — or `"skipped"` if below relevance threshold |
| Semantic search | `GET /api/search/semantic?path=P&q=Q&top_k=N` | Top N modules + functions ranked by semantic similarity to concept Q |
| Embedding status | `GET /api/search/semantic/status?path=P` | Module/function vector counts, availability |

**Preflight Contract Checklist** (`POST /api/briefing/preflight`) is the primary planning endpoint. Body:
```json
{"prompt": "Refactor the approval flow", "path": "C:/Development/GitHub/Giulia", "top_k": 5, "depth": 2}
```

Given a natural language prompt, it:
1. **Discovers** relevant modules via semantic search (Bumblebee embeddings)
2. **Pre-computes** change risk scores (called once, cached in pipeline)
3. **Builds 6 contract sections** per module:
   - **Behaviour Contract** — callbacks defined/implemented, optional callbacks, integrity status (4-level: `consistent`, `consistent_with_optionals`, `heuristic_match`, `fractured`), missing callbacks, optional omitted, heuristic injected
   - **Type Contract** — specs with full signatures, types, spec coverage ratio
   - **Data Contract** — struct fields, dependents count
   - **Macro Contract** — `use` directives, known implications (GenServer requires init/1, etc.)
   - **Topology** — centrality, dependents list, change risk score/rank, full impact map
   - **Semantic Integrity** — cosine similarity to prompt, drift flag if module doesn't match intent
4. **Summarizes** aggregate counts: hubs, high-risk modules, fractured behaviours, semantic drift

One call replaces the 4 separate queries previously required for planning mode.

**Surgical Briefing** (`GET /api/intelligence/briefing`) is the lighter alternative, used automatically during inference:
1. **Layer 1** (Bumblebee): Finds the top 3 most relevant modules and top 5 functions via cosine similarity
2. **Layer 2** (Knowledge Graph): Enriches each module with centrality (hub score), dependents count, and file path
3. Returns a formatted briefing with hub warnings for high-centrality modules (in_degree >= 3)

### 4. Runtime Introspection (Build 92)

Live BEAM runtime awareness — what your code is *doing* right now, not just what it *is*.

| Intent | Endpoint | Returns |
|--------|----------|---------|
| **BEAM health** | `GET /api/runtime/pulse` | Processes, memory (with breakdown), schedulers, uptime, run queue, ETS tables (top 5 "god tables"), warnings |
| **Top processes** | `GET /api/runtime/top_processes?metric=M` | Top 10 processes by metric (`reductions`, `memory`, `message_queue`). Shows PID, module, registered name, current function |
| **Hot spots** | `GET /api/runtime/hot_spots?path=P` | Top 5 modules by runtime activity, fused with Knowledge Graph data (zone, complexity, centrality). The differentiator: PID → Module → Graph in one response |
| **Function trace** | `GET /api/runtime/trace?module=M&duration=5000` | Short-lived per-module call frequency trace. Hard limits: max 1,000 events OR 5 seconds (whichever first). Returns sorted call counts with `aborted` flag if kill switch fires |
| **Snapshot history** | `GET /api/runtime/history?last=N` | Last N Collector snapshots (default 20, 30s interval = 10 min window). Each snapshot includes pulse + top processes |
| **Metric trend** | `GET /api/runtime/trend?metric=M` | Time-series for one metric (`memory`, `processes`, `run_queue`, `ets_memory`) — for charting and leak detection |
| **Active alerts** | `GET /api/runtime/alerts` | Warnings with duration: high memory, process count, run queue pressure, message queue buildup, memory growth (>20% over window) |
| **Connect remote node** | `POST /api/runtime/connect` | Connect to a remote BEAM node. Body: `{"node":"myapp@host","cookie":"secret"}` |

All runtime endpoints accept an optional `?node=N` parameter (default: local Giulia node). The `?path=P` parameter on `hot_spots` enables Knowledge Graph fusion.

### 5. Plan Validation Gate (Build 93)

**After planning, before writing code**: validate your plan against the Knowledge Graph.

| Intent | Endpoint | Returns |
|--------|----------|---------|
| **Validate plan** | `POST /api/plan/validate` | Verdict (`approved`/`warning`/`rejected`), risk score 0-100, 5 check results, actionable recommendations |

**Request format:**
```json
{
  "path": "C:/Development/GitHub/Giulia",
  "plan": {
    "modules_touched": ["Giulia.Context.Store", "Giulia.Knowledge.Store"],
    "actions": [
      {"type": "modify", "module": "Giulia.Context.Store"},
      {"type": "create", "module": "Giulia.Runtime.Inspector", "depends_on": ["Giulia.Knowledge.Store"]}
    ]
  }
}
```

**Five validation checks:**
1. **Cycle detection** — clones graph, adds proposed edges, detects new circular dependencies → `rejected` if new cycles
2. **Red zone collision** — counts red-zone modules (heatmap score ≥60) in plan → `warning` if ≥2 red zones touched
3. **Hub risk aggregation** — sums centrality degrees across touched modules → `warning` if total > 40
4. **Blast radius preview** — union of all downstream dependents → info with count
5. **Unprotected hub write** — checks if plan modifies hub modules with low spec coverage → `warning` with coverage data

**Verdicts:**
- `approved` — all checks pass, proceed without justification
- `warning` — acknowledge each warning and explain why you're proceeding
- `rejected` — **do not write code**, revise the plan first

### 6. Modifying Code

Send natural language commands through Giulia's OODA orchestrator. Two endpoints available:

| Intent | Endpoint | Returns |
|--------|----------|---------|
| Streaming command (preferred) | `POST /api/command/stream` | SSE stream with real-time OODA steps (tool calls, approvals, completion). Body: `{"message":"...","path":"P"}` |
| Synchronous command | `POST /api/command` | Blocking JSON response. Body: `{"message":"...","path":"P"}` or `{"command":"init\|status\|projects","path":"P"}` |

**Request format:**
```json
{"message": "your instruction here", "path": "C:/Development/GitHub/ProjectName"}
```

**Good commands** (specific, actionable, name the tool when possible):
```
"In Giulia.Tools.Registry, rename the function 'execute' to 'dispatch'. Use rename_mfa."
"Add a @spec to all public functions in Giulia.Context.Store."
"Extract the private helpers parse_args/1 and validate_opts/1 from Giulia.Inference.Orchestrator into a new module Giulia.Inference.Utils."
"In Giulia.Tools.ReadFile, add a max_lines parameter with default 1000. Update the execute/2 function to respect it."
"Replace all occurrences of 'alias Giulia.Old.Module' with 'alias Giulia.New.Module' across the codebase."
```

**Poor commands** (vague, the orchestrator will loop):
```
"Make the code better."
"Fix all the bugs."
"Refactor everything."
```

**Boundaries**: The orchestrator works best with single, concrete tasks. It can handle multi-file changes atomically but struggles with open-ended exploration. For tasks like "understand this codebase" or "find all performance bottlenecks," use the read-only endpoints directly.

**SSE event types** returned by the stream:
- `model_detected` — which LLM model is handling the request
- `tool_call` / `tool_result` — tool invoked and its outcome
- `transaction_auto_enabled` — staging mode activated (hub module detected)
- `commit_started` / `commit_compiling` / `commit_compile_passed` / `commit_integrity_passed` / `commit_success` — transactional commit lifecycle
- `tool_requires_approval` — dangerous operation needs approval (see Approval Flow below)
- `complete` — final response with result

**Approval flow**: When the orchestrator encounters a high-risk operation (writing to a hub module with centrality > 3), it emits `tool_requires_approval` with an `approval_id`. To proceed:
1. Present the operation details to the user (tool name, parameters, preview diff)
2. If the user approves: `POST /api/approval/:approval_id` with `{"approved": true}`
3. If the user rejects: `POST /api/approval/:approval_id` with `{"approved": false}`
4. Do NOT auto-approve — the approval gate exists to catch destructive changes to critical modules

**Approval endpoints:**

| Intent | Endpoint | Returns |
|--------|----------|---------|
| List pending approvals | `GET /api/approvals` | All pending approval requests with count |
| Get approval details | `GET /api/approval/:id` | Info about a specific pending approval request |
| Respond to approval | `POST /api/approval/:id` | Approve or reject. Body: `{"approved": true\|false}` |

### 7. Verifying Changes

| Intent | Method |
|--------|--------|
| Re-index after file changes | `POST /api/index/scan` with `{"path": "/projects/Giulia"}` |
| Check behaviour contracts | `GET /api/knowledge/integrity` |
| View transaction state | `GET /api/transaction/staged?path=P` |
| Toggle transaction mode | `POST /api/transaction/enable` with `{"path":"P"}` — toggles on/off, returns new state |
| Reset transaction mode | `POST /api/transaction/rollback` with `{"path":"P"}` — disables transaction mode |
| Debug last inference | `GET /api/agent/last_trace` |
| Compile check | `mix compile --all-warnings` (shell) |
| Run tests | `mix test` (shell) |

## Workflow Guidance

### Planning Mode (MANDATORY)

When entering plan mode for any Elixir code modification, you **MUST** query Giulia's analysis endpoints BEFORE writing the plan. Do NOT use grep, awk, sed, or find to discover module dependencies — Giulia's Knowledge Graph has this data pre-indexed from AST analysis.

**First call MUST be Preflight:**
```bash
curl -X POST http://localhost:4000/api/briefing/preflight \
  -H "Content-Type: application/json" \
  -d '{"prompt":"your task description","path":"C:/Development/GitHub/ProjectName"}'
```

This single call returns all 6 contract sections per relevant module — behaviour obligations, type contracts, struct dependencies, macro implications, topology (centrality + impact + change risk), and semantic integrity. **One call replaces four.**

**For modules NOT in the preflight result** (or for deeper investigation), use individual queries:
1. `GET /api/knowledge/change_risk?path=P` — identify which modules are dangerous to touch
2. `GET /api/knowledge/impact?path=P&module=X&depth=2` — blast radius for every module you plan to modify
3. `GET /api/knowledge/centrality?path=P&module=X` — hub score (degree > 3 = high-risk)
4. `GET /api/index/module_details?path=P&module=X` — full API surface of target modules
5. `POST /api/knowledge/pre_impact_check` — before renaming/removing a function or module, get affected callers, risk score, and phased migration plan
6. `GET /api/knowledge/heatmap?path=P` — module health overview: red/yellow/green zones by composite score
7. `GET /api/knowledge/logic_flow?path=P&from=MFA&to=MFA` — trace function-call path between two MFA vertices
8. `GET /api/knowledge/audit?path=P` — unified audit combining unprotected hubs, struct lifecycle, semantic duplicates, and behaviour integrity in one call
9. `GET /api/knowledge/unprotected_hubs?path=P` — find hub modules with insufficient spec/doc coverage (dangerous gaps)
10. `GET /api/knowledge/struct_lifecycle?path=P` — trace struct data flow across modules (creators, consumers, logic leaks)
11. `GET /api/knowledge/duplicates?path=P` — find semantically similar functions via embedding cosine similarity

**No plan is valid without blast radius data.** If you skip preflight AND these queries, the plan is incomplete.

### Planning Protocol (NON-NEGOTIABLE)

When formulating a multi-file refactor or any modification touching 2+ modules:
1. You **MUST** format your plan as a JSON object matching the `/api/plan/validate` schema
2. You **MUST** call `POST /api/plan/validate` with that plan
3. If the verdict is `REJECTED`, you are **FORBIDDEN** from writing code. Revise the plan.
4. If the verdict is `WARNING`, you must acknowledge each warning and explain why you're proceeding
5. Only `APPROVED` plans may be executed without justification

### Before Modifying Any Elixir Module

1. **Understand** — `GET /api/index/module_details?path=P&module=X` to get the full picture (functions, types, specs, callbacks)
2. **Assess impact** — `GET /api/knowledge/impact?path=P&module=X&depth=2` to see who depends on it and what it depends on
3. **Check hub score** — `GET /api/knowledge/centrality?path=P&module=X` — if degree > 3, changes are high-risk
4. **Make changes** — edit files directly or use `POST /api/command/stream` for complex refactoring
5. **Re-index** — `POST /api/index/scan` so the index reflects your changes
6. **Verify integrity** — `GET /api/knowledge/integrity` to catch behaviour-implementer fractures early

### Critical Rule: Re-index After Direct Edits

If you edit Elixir files directly (using file write/edit tools instead of Giulia's command/stream), the ETS index and Knowledge Graph become stale. **Always call `POST /api/index/scan` after direct file modifications.** Without this, subsequent calls to `/api/index/*` and `/api/knowledge/*` will return outdated information. The scan takes ~2-5 seconds and rebuilds everything.

### Choosing Giulia vs Shell Tools

| Need | Use |
|------|-----|
| Module/function metadata | Giulia `/api/index/*` — instant, structured, no parsing needed |
| Full module profile | Giulia `/api/index/module_details` — one call for everything |
| Blast radius before refactoring | Giulia `/api/knowledge/*` — topology-aware, not just text matching |
| Code search | Giulia `/api/search` — project-scoped, sandboxed |
| File contents | Standard file read tools — Giulia doesn't serve raw file content |
| Compile/test | Shell — `mix compile`, `mix test` |

### Report Output Convention (MANDATORY)

When a report or assessment is requested (project audit, health check, analysis, code review, etc.), you **MUST** produce a comprehensive Markdown report file with this naming convention:

```
<projectfolder>_REPORT_<AAAAMMHH>.md
```

- `<projectfolder>` — the project directory name (e.g., `Giulia`, `MyApp`)
- `<AAAAMMHH>` — timestamp: year (4 digits) + month (2 digits) + hour (2 digits)

**Example:** `Giulia_REPORT_20260211.md`

The report must be saved in the project root. Do not skip file creation — a verbal summary alone is insufficient when a report or assessment is requested.

### Path Convention

**All index and knowledge endpoints require a `?path=P` query parameter** identifying which project to query. This is because Giulia supports multi-project isolation — each scanned project has its own ETS namespace and Knowledge Graph. Without `?path=`, these endpoints return a 400 error.

Use the host path (e.g., `path=C:/Development/GitHub/Giulia`). The daemon translates to container paths automatically via PathMapper.

Example: `GET /api/knowledge/stats?path=C:/Development/GitHub/Giulia`

The `POST /api/index/scan` and `POST /api/command/stream` endpoints take `path` in the JSON body instead (unchanged).
