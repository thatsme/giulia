# SKILL.md — Giulia Code Intelligence

## What is Giulia?

Giulia is a REST API daemon (port 4000) that provides AST-level code intelligence for Elixir projects. It maintains a persistent Knowledge Graph, ETS-backed module/function index, and Sourceror-parsed AST cache across sessions. Prefer Giulia's API over shell tools (grep, find, cat) when the daemon is available — it returns structured, pre-indexed data instantly.

## Detection

Before using any Giulia endpoint, verify the daemon is running:

```
curl -s http://localhost:4000/health
```

Expected: `{"status":"ok","node":"...","version":"..."}`.
If this fails, fall back to standard file tools. Do not retry.

## Tool Categories

### 1. Understanding Code

Use these to inspect modules, functions, types, and dependencies before making changes.

| Intent | Endpoint | Returns |
|--------|----------|---------|
| Everything about a module | `GET /api/index/module_details?module=X` | File path, moduledoc, public/private functions, types, specs, callbacks, struct fields — the single most useful call before modifying anything |
| List all modules | `GET /api/index/modules` | All indexed module names with file paths |
| Functions in a module | `GET /api/index/functions?module=X` | Name, arity, line number, type (def/defp) |
| Project shape | `GET /api/index/summary` | Module count, function count, types, specs, callbacks |
| Search code patterns | `GET /api/search?pattern=X&path=Y` | Regex search scoped to project (sandboxed) |
| What X depends on | `GET /api/knowledge/dependencies?module=X` | Upstream dependencies |
| Index status | `GET /api/index/status` | Scanning state, file count, last scan time |

### 2. Analyzing Impact

Use these BEFORE modifying any shared module. They reveal the blast radius.

| Intent | Endpoint | Returns |
|--------|----------|---------|
| Full impact map | `GET /api/knowledge/impact?module=X&depth=N` | Upstream + downstream modules at depth N |
| Who depends on X | `GET /api/knowledge/dependents?module=X` | All downstream consumers (blast radius) |
| Hub score | `GET /api/knowledge/centrality?module=X` | In-degree, out-degree — high = dangerous to modify |
| Dependency path | `GET /api/knowledge/path?from=A&to=B` | Shortest path between two modules |
| Graph overview | `GET /api/knowledge/stats` | Vertices, edges, components, top hubs |
| Behaviour integrity | `GET /api/knowledge/integrity` | Checks all behaviour-implementer contracts match |
| Dead code | `GET /api/knowledge/dead_code` | Functions defined but never called anywhere — excludes OTP callbacks, behaviour implementations, framework entry points |
| Circular dependencies | `GET /api/knowledge/cycles` | Strongly connected components in the module dependency graph — modules that depend on each other in a cycle |
| God modules | `GET /api/knowledge/god_modules` | Top 20 modules ranked by weighted score: function count + complexity + centrality — refactoring targets |
| Orphan specs | `GET /api/knowledge/orphan_specs` | @spec declarations where no matching function definition exists (name/arity mismatch) |
| Fan-in / fan-out | `GET /api/knowledge/fan_in_out` | Modules ranked by incoming + outgoing dependency count — high fan-out = knows too much, high fan-in = too many dependents |
| Coupling score | `GET /api/knowledge/coupling` | Top 50 module pairs ranked by how many function calls flow between them — tight coupling quantified |
| API surface | `GET /api/knowledge/api_surface` | Public vs private function ratio per module — high ratio = poor encapsulation |
| Change risk | `GET /api/knowledge/change_risk` | Composite score: centrality + complexity + fan-in/out + coupling + API surface — "refactor this first" prioritized list |

### 3. Modifying Code

Send natural language commands through Giulia's OODA orchestrator via `POST /api/command/stream`. It uses AST analysis, the Knowledge Graph, and transactional staging to make changes atomically.

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

### 4. Verifying Changes

| Intent | Method |
|--------|--------|
| Re-index after file changes | `POST /api/index/scan` with `{"path": "/projects/Giulia"}` |
| Check behaviour contracts | `GET /api/knowledge/integrity` |
| View transaction state | `GET /api/transaction/staged?path=...` |
| Debug last inference | `GET /api/agent/last_trace` |
| Compile check | `mix compile --all-warnings` (shell) |
| Run tests | `mix test` (shell) |

## Workflow Guidance

### Before Modifying Any Elixir Module

1. **Understand** — `GET /api/index/module_details?module=X` to get the full picture (functions, types, specs, callbacks)
2. **Assess impact** — `GET /api/knowledge/impact?module=X&depth=2` to see who depends on it and what it depends on
3. **Check hub score** — `GET /api/knowledge/centrality?module=X` — if degree > 3, changes are high-risk
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

### Path Convention

When calling Giulia endpoints that take a `path` parameter, use the host path (e.g., `C:/Development/GitHub/Giulia`). The daemon translates to container paths automatically via PathMapper.
