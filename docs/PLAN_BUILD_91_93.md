# Build 91-93 Strategic Expansion Plan

## Context

Giulia at build 90 has a mature code intelligence layer (72 modules, 1,079 graph vertices, 1,309 edges) but its value is locked behind individual API calls. Claude Code must know *which* endpoints to call and *when*. The strategic expansion addresses three gaps:

1. **Cold start problem** — Every Claude Code session starts ignorant of project topology
2. **No runtime awareness** — Graph is static; no visibility into live process health
3. **No plan validation** — Claude Code can start writing code with a plan that violates the graph

The original Build 91 (Expansion-Aware Integrity Check) is **already complete** — behaviour integrity returns 0 fractures after build 90's MacroMap + optional callback heuristic. We repurpose that slot.

---

## Build 91: Architect Brief (replaces original Build 91)

### Goal
Single endpoint that returns everything a Software Architect needs to understand the project in one call. Claude Code fetches this at session start — zero manual prompting.

### New file: `lib/giulia/intelligence/architect_brief.ex`

Pure functional module (no GenServer), follows `Preflight` pattern:

```
ArchitectBrief.build(project_path, opts \\ [])
  → {:ok, %{...}} | {:error, term()}
```

Composes data from existing sources (all already implemented):

| Section | Source | Function |
|---------|--------|----------|
| `project` | `Context.Store` | `project_summary/1` → file/module/function counts |
| `hubs` | `Knowledge.Store` | `stats/1` → top N hubs by degree |
| `heatmap` | `Knowledge.Store` | `heatmap/1` → red/yellow/green zones with scores |
| `cycles` | `Knowledge.Store` | `find_cycles/1` → circular dependency list |
| `unprotected_hubs` | `Knowledge.Store` | `find_unprotected_hubs/2` → spec coverage gaps |
| `integrity` | `Knowledge.Store` | `check_all_behaviours/1` → fracture status |
| `god_modules` | `Knowledge.Store` | `find_god_modules/1` → complexity hotspots |
| `constitution` | `ProjectContext` | GIULIA.md tech stack + taboos (if project initialized) |

Each section independently error-handled with fallback values (partial failure tolerance).

Response shape:
```json
{
  "brief_version": "build_91",
  "timestamp": "2026-02-16T...",
  "project": { "files": 72, "modules": 72, "functions": 1007, ... },
  "topology": {
    "vertices": 1079, "edges": 1309,
    "hubs": [{"module": "Tools.Registry", "degree": 30}, ...],
    "cycles": [],
    "god_modules": [...]
  },
  "health": {
    "heatmap_summary": {"red": 7, "yellow": 49, "green": 16},
    "red_zones": [{"module": "Context.Store", "score": 78}, ...],
    "unprotected_hubs": {"count": 8, "red": 6, "yellow": 2},
    "integrity": "consistent"
  },
  "constitution": { "tech_stack": "...", "taboos": [...] }  // null if no GIULIA.md
}
```

### New route in `lib/giulia/daemon/endpoint.ex`

```
GET /api/brief/architect?path=P
```

~20 lines in Endpoint — calls `ArchitectBrief.build/2`, sends JSON.

### SKILL.md update

Add to the "Session Start" section:
```
Before any work, always call: GET /api/brief/architect?path=<CWD>
```

### Files touched
- **NEW**: `lib/giulia/intelligence/architect_brief.ex` (~150 lines)
- **EDIT**: `lib/giulia/daemon/endpoint.ex` (add 1 route, ~20 lines)
- **EDIT**: `SKILL.md` + `docs/SKILL.md` (add session-start instruction)

### Blast radius: Zero
Pure composition of existing read-only functions. No changes to Store, Knowledge, or any existing module.

---

## Build 92: Runtime Proprioception — The Live Sensor

### Philosophy

Static analysis tells you what your code *is*. Runtime tells you what your code *does*.
The graph shows you every road. The runtime shows you where the traffic jams are.

Most AI tools are "Dead-Code Oriented" — they see the script but not the ghost in the machine.
Build 92 gives Giulia the ability to answer: "Don't just tell me what the code says; tell me what the machine is currently doing."

This is the bridge from Static Map to Live Sensor.

### Phase A: Inspector — The Nerves

**New file: `lib/giulia/runtime/inspector.ex`**

The Inspector exploits Distributed Erlang to "attach" to any running BEAM node and harvest runtime data using `:runtime_tools` and `:observer_backend`.

**Node discovery** (in order of priority):
1. Explicit `node` parameter in API call
2. Auto-detect from `.node_name` file in project root (e.g., `echo "myapp@127.0.0.1" > .node_name`)
3. Fall back to `:local` (Giulia self-introspection)

**Cookie authentication** (the wall you must pass):
In the BEAM, you cannot connect to a node unless you share the Magic Cookie. If Dockerized Giulia runs with one cookie and the target app runs with another, `Node.connect` will fail silently.

Resolution order:
1. Explicit `cookie` parameter in `POST /api/runtime/connect` body
2. `GIULIA_RUNTIME_COOKIE` environment variable
3. `~/.erlang.cookie` (BEAM default)

Without this, the Live Sensor is blind to 90% of external projects.

**Core functions:**

```
Inspector.connect(node_ref, opts \\ [])
  opts: [cookie: "override_cookie"]
  → :ok | {:error, :node_unreachable} | {:error, :auth_failed}

Inspector.pulse(node_ref)
  → {:ok, %{
      node: :"myapp@192.168.1.50",
      timestamp: ~U[...],
      beam: %{
        processes: N, memory_mb: N, schedulers: N,
        uptime_seconds: N, run_queue: N
      },
      ets: %{
        tables: N, total_memory_mb: N,
        god_tables: [%{name: X, size: N, memory_mb: N}, ...]
      },
      warnings: [...]
    }}

Inspector.top_processes(node_ref, metric)
  metric = :reductions | :memory | :message_queue
  → {:ok, [
      %{pid: "#PID<0.450.0>", registered_name: "Elixir.MyApp.Worker",
        module: "MyApp.Worker", reductions: 2_340_000, memory_kb: 512,
        message_queue: 3, current_function: {MyApp.Worker, :handle_call, 3}},
      ...
    ]}   # Top 10

Inspector.hot_spots(node_ref)
  → {:ok, [
      %{module: "MyApp.Zone.Tick", reductions_pct: 60.2,
        memory_mb: 45.3, message_queue: 234,
        knowledge_graph: %{complexity: 90, centrality: 24, zone: :red}},
      ...
    ]}   # Top 5 modules — PID resolved to module, merged with Knowledge Graph
```

**Implementation — what to harvest:**

| Data | Source | Why |
|------|--------|-----|
| Process reductions | `:observer_backend.pro_info/2` or `:erlang.process_info(pid, :reductions)` | Who is doing the most work right now? |
| Mailbox sizes | `:erlang.process_info(pid, :message_queue_len)` | Which process is choking? (bottlenecks) |
| Binary/heap memory | `:erlang.process_info(pid, [:binary, :heap_size, :total_heap_size])` | Who is leaking memory or holding large blobs? |
| ETS stats | `:ets.all/0` + `:ets.info(tab, [:size, :memory, :name])` | Which tables are becoming "God Tables"? |
| Process reductions | `:runtime_tools` via `:rpc.call` | System-wide CPU distribution |
| Current function | `:erlang.process_info(pid, :current_function)` | What is each process doing right now? |

**The PID → Module → Graph resolution chain** (critical):
1. Get PID from process list
2. Resolve to registered name or initial call module via `:erlang.process_info`
3. Map module atom to Knowledge Graph vertex
4. Attach static metadata (complexity, centrality, zone, dependents)
5. Return fused result: live stats + graph position in one response

**Safety:**
- All remote calls via `:rpc.call/5` with explicit timeout (default: 5_000ms)
- If target node is non-responsive → `{:error, :node_unreachable}` (no crash, no retry, no hang)
- Read-only introspection — never modifies state on the target node

### Phase B: Collector — Temporal Awareness

**New file: `lib/giulia/runtime/collector.ex`**

GenServer that periodically calls `Inspector.pulse/1` and stores the results in a rolling buffer.

```
Collector.start_link(node: :local, interval_ms: 30_000)
Collector.history(node, last_n: 60)        → last 60 snapshots (~30 min at 30s interval)
Collector.trend(node, :memory)             → [{timestamp, value}, ...] for charting
Collector.alerts(node)                     → active warnings with duration and first_seen
```

**Storage: 10-minute rolling buffer in ETS**
- ETS ring buffer per connected node, overwrites oldest entry
- Default: 20 entries at 30s interval = 10 minutes of high-resolution data
- Configurable up to 600 entries (5 hours) if RAM allows — on a 128GB machine, this is negligible
- Each entry: `{timestamp, pulse_map, top_processes_snapshot}`

**Temporal intelligence this enables:**
- "Knowledge.Store message queue has been above 100 for 5 minutes" (not just "it's 450 right now")
- "Memory grew 40% in the last 10 minutes" (leak detection)
- "Inference.Pool reductions tripled after the last scan" (correlation)
- "MyApp.Worker was the top CPU consumer in 18 of the last 20 snapshots" (persistent hot spot)

### Phase C: Short-lived Trace (per-module call frequency)

**Added to `lib/giulia/runtime/inspector.ex`**

```
Inspector.trace(node_ref, module, duration_ms \\ 5_000)
  → {:ok, %{
      module: "MyApp.Zone.Tick",
      duration_ms: 5000,     # actual duration (may be shorter if kill switch triggered)
      aborted: false,        # true if kill switch fired
      calls: [
        %{function: :handle_call, arity: 3, count: 1_240},
        %{function: :tick, arity: 1, count: 5_000},
        %{function: :broadcast, arity: 2, count: 5_000},
      ],
      total_calls: 11_240,
      calls_per_second: 2_248.0
    }}
  | {:ok, %{aborted: true, reason: "High-frequency function detected (>1000 events in 200ms). Use sampling instead.", ...}}
```

**Overload Protection — the Kill Switch:**

Tracing on a high-traffic node is like performing surgery on a marathon runner while they're racing. If the model asks for a 5-second trace on a function called 100,000 times/sec, you will freeze the VM.

Hard limits (non-negotiable):
- **Max events: 1,000** — if the event buffer fills before duration expires, trace stops immediately
- **Max duration: 5 seconds** — hard cap regardless of what the API caller requests
- **Whichever comes first wins** — the trace self-terminates at the first limit hit
- If aborted due to event overflow: return partial results + `aborted: true` + reason explaining to use sampling instead

Implementation:
- Sets up `:erlang.trace` on the target node via `:rpc.call` for a specific module
- A monitor process watches the event count — kills the trace if it exceeds 1,000
- `:erlang.trace` flag `:call` with match spec limited to the target module
- Automatically stops tracing when window expires (safety — never leave traces running)
- Returns sorted by call count descending

This is the bridge to Build 94's Runtime Graph — but it's useful standalone: "which functions in this module are actually hot?"

### Phase D: Endpoints — The AISP Interface

```
GET  /api/runtime/pulse?path=P&node=N              → high-level BEAM health (Inspector.pulse)
GET  /api/runtime/top_processes?path=P&node=N&metric=reductions → top 10 by metric (Inspector.top_processes)
GET  /api/runtime/hot_spots?path=P&node=N           → top 5 modules fused with Knowledge Graph (Inspector.hot_spots)
GET  /api/runtime/trace?path=P&node=N&module=M&duration=5000 → short-lived function call trace (Inspector.trace)
GET  /api/runtime/history?path=P&node=N&last=20     → last N collected snapshots (Collector.history)
GET  /api/runtime/trend?path=P&node=N&metric=memory → time-series for one metric (Collector.trend)
GET  /api/runtime/alerts?path=P&node=N              → active warnings with duration (Collector.alerts)
POST /api/runtime/connect                           → connect to remote node. Body: {"node": "myapp@host", "cookie": "secret"}
```

`node` is optional everywhere — omitted = auto-detect from `.node_name`, then fall back to `:local`.

### Phase E: Integration — The Fusion Points

**1. Architect Brief (Build 91):**
Add `runtime` section when Collector is active:
- Current BEAM health (pulse)
- Active alerts with duration
- Top 5 hot spots (fused with graph data)

**2. Preflight Contract Checklist:**
When runtime data is available, flag hot spots in the preflight report:
```json
{
  "module": "MyApp.Zone.Tick",
  "topology": { "centrality": 24, "zone": "red" },
  "runtime_alert": "LIVE PERFORMANCE ALERT: 60% of system reductions, message queue 234, growing for 8 minutes"
}
```

This is where Giulia beats every other tool. Claude Code asks "why is the system slow?":
1. Giulia calls `hot_spots` — identifies PID <0.450.0> eating 60% CPU
2. Resolves PID → `MyApp.Zone.Tick`
3. Checks Knowledge Graph: complexity 90, 24 dependents, red zone
4. Returns: *"MyApp.Zone.Tick is responsible for 60% of system load. It is a 90-complexity God Module with 24 dependents. Recommend splitting its main loop into concurrent sub-tasks."*

Static intelligence + live telemetry = actionable diagnosis.

### Implementation Order (First Strike)

1. **Inspector.connect/2 + Inspector.pulse/1** — detect if a node is reachable (with cookie auth), return basic health
2. **Inspector.top_processes/2** — top 10 by reductions/memory/queue
3. **Inspector.hot_spots/1** — PID → Module → Knowledge Graph fusion (the differentiator)
4. **Endpoints**: `pulse`, `top_processes`, `hot_spots` (3 routes, prove the concept)
5. **Collector** — periodic snapshots, ETS ring buffer, `history`/`trend`/`alerts`
6. **Inspector.trace/3** — short-lived per-module function tracing
7. **Preflight integration** — `LIVE PERFORMANCE ALERT` flags
8. **Remaining endpoints**: `trace`, `history`, `trend`, `alerts`, `connect`

Steps 1-4 are the "First Strike" — prove runtime-to-graph fusion works. Everything else layers on top.

### Files touched
- **NEW**: `lib/giulia/runtime/inspector.ex` (~300 lines)
- **NEW**: `lib/giulia/runtime/collector.ex` (~200 lines)
- **EDIT**: `lib/giulia/daemon/endpoint.ex` (add 8 routes, ~100 lines)
- **EDIT**: `lib/giulia/intelligence/architect_brief.ex` (add runtime section, ~20 lines)
- **EDIT**: `lib/giulia/intelligence/preflight.ex` (add LIVE PERFORMANCE ALERT, ~30 lines)
- **EDIT**: `lib/giulia/application.ex` (add Collector to supervision tree)

### Blast radius: Zero
Read-only BEAM introspection via `:rpc.call` with timeouts. Collector is a new supervised process. Short-lived traces auto-terminate. No changes to existing GenServers. Remote nodes only need distribution enabled (`--name` + `--cookie`).

---

## Build 93: Plan Validation Gate

### Goal
Claude Code sends a proposed plan (list of modules to modify + actions). Giulia validates it against the Knowledge Graph and returns a verdict before any code is written.

### New file: `lib/giulia/intelligence/plan_validator.ex`

Pure functional module:

```
PlanValidator.validate(plan, project_path, opts \\ [])
  → {:ok, %{verdict: :approved | :warning | :rejected, ...}}
```

Input schema (kept intentionally minimal — expand based on real usage):
```json
{
  "modules_touched": ["Giulia.Context.Store", "Giulia.Knowledge.Store"],
  "actions": [
    {"type": "modify", "module": "Giulia.Context.Store"},
    {"type": "create", "module": "Giulia.Runtime.Inspector"}
  ]
}
```

Validation checks (all use existing read-only Knowledge Graph queries):

| Check | Source | Verdict |
|-------|--------|---------|
| **Cycle introduction** | Clone graph, add proposed edges, run `Analyzer.cycles/1` | `:rejected` if new cycles |
| **Red zone collision** | `heatmap/1` — count red-zone modules in plan | `:warning` if ≥ 2 red zones touched |
| **Hub risk aggregation** | `centrality/2` per module — sum degrees | `:warning` if total degree > threshold |
| **Blast radius preview** | `impact_map/3` per module — union of downstream | Info: total downstream affected |
| **Unprotected hub write** | `find_unprotected_hubs/2` — check if plan modifies any | `:warning` with spec coverage data |

Response shape:
```json
{
  "verdict": "warning",
  "risk_score": 45,
  "checks": [
    {"check": "cycle_detection", "status": "pass", "detail": "No new cycles"},
    {"check": "red_zone_collision", "status": "warning", "detail": "2 red-zone modules: Store (78), Analyzer (64)"},
    {"check": "hub_risk", "status": "pass", "detail": "Total degree: 35"},
    {"check": "blast_radius", "status": "info", "detail": "12 downstream modules affected"},
    {"check": "unprotected_write", "status": "warning", "detail": "Store has 0% spec coverage"}
  ],
  "recommendations": [
    "Add @spec to Context.Store before modifying (0% coverage, degree 21)",
    "Consider splitting the plan: modify Store and Analyzer in separate commits"
  ]
}
```

### New route in `lib/giulia/daemon/endpoint.ex`

```
POST /api/plan/validate
Body: {"path": "P", "plan": {...}}
```

### The Planning Protocol Enforcer

Claude Code doesn't "know" it should send a JSON plan. Left to its own devices, it will write a Markdown list and start coding. The Brain (Claude) must be physically gated by the Exoskeleton (Giulia).

**CLAUDE.md update** (global `~/.claude/CLAUDE.md`):
Add a "Planning Protocol" section:

```markdown
### Planning Protocol (NON-NEGOTIABLE)

When formulating a multi-file refactor or any modification touching 2+ modules:
1. You MUST format your plan as a JSON object matching the `/api/plan/validate` schema
2. You MUST call `POST /api/plan/validate` with that plan
3. If the verdict is `REJECTED`, you are FORBIDDEN from writing code. Revise the plan.
4. If the verdict is `WARNING`, you must acknowledge each warning and explain why you're proceeding
5. Only `APPROVED` plans may be executed without justification
```

**SKILL.md update:**
Document the endpoint, schema, and expected workflow. Add to the "Session Start" sequence:
```
After planning, before writing code: POST /api/plan/validate with your plan JSON
```

Without this enforcement, the validation gate exists but nobody walks through it.

### Files touched
- **NEW**: `lib/giulia/intelligence/plan_validator.ex` (~250 lines)
- **EDIT**: `lib/giulia/daemon/endpoint.ex` (add 1 route, ~25 lines)
- **EDIT**: `SKILL.md` + `docs/SKILL.md` (document the endpoint + planning protocol)
- **EDIT**: `~/.claude/CLAUDE.md` (add Planning Protocol enforcement)

### Blast radius: Low
Read-only consumption of Knowledge Graph. The cycle detection clone is a temporary in-memory copy — no mutation of the real graph. The CLAUDE.md change is a behavioral gate — no code impact.

---

## Build 94: Runtime Graph (future — depends on 92)

### Goal
The second knowledge layer. Same modules, same edges as the static graph — but weighted by actual runtime traffic. This is where static analysis and runtime awareness merge.

### What it enables

| Static graph says | Runtime graph adds | Combined intelligence |
|-------------------|-------------------|----------------------|
| "Module A depends on Module B" | "A calls B 10,000 times/sec" | "This is a hot dependency — refactor with caution" |
| "Function X has 0 callers" | "X had 0 invocations in 48 hours" | "Provably dead code — safe to remove" |
| "Registry has 30 dependents" | "Only 3 call it at runtime" | "Real blast radius is 3, not 30" |
| "Context.Store is red zone (score 78)" | "Store handles 500 calls/sec, queue growing" | "Red zone AND under load — do not touch right now" |
| "Heatmap ranks by complexity + centrality" | "Add call frequency + queue pressure" | "Runtime-weighted heatmap — the real priority list" |

### Architecture

```
┌─────────────────────────────────────────────────────┐
│                   GIULIA DAEMON                      │
│                                                      │
│  ┌──────────────┐         ┌──────────────┐          │
│  │  Knowledge    │         │   Runtime     │          │
│  │  Graph        │◄────────│   Graph       │          │
│  │  (static AST) │  merge  │  (live BEAM)  │          │
│  └──────┬───────┘         └──────┬───────┘          │
│         │                        │                   │
│         ▼                        ▼                   │
│  ┌─────────────────────────────────────────┐        │
│  │         Merged Intelligence              │        │
│  │  - Runtime-weighted heatmap              │        │
│  │  - Provable dead code                    │        │
│  │  - True blast radius (traffic-filtered)  │        │
│  │  - Load-aware refactoring advice         │        │
│  └─────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────┘
```

### Implementation approach (to be detailed when Build 92 is complete)

1. **Call frequency tracking** — Uses Build 92's `Inspector.trace/3` data. Giulia sends a trace request, collects MFA call counts over a window (respecting the kill switch limits), stops tracing.
2. **Runtime edge weights with TTL** — Overlay call counts onto static graph edges. New edge attribute:
   ```
   %{static: true, runtime_calls: 10_432, last_sampled: ~U[...], ttl_minutes: 10}
   ```
3. **Runtime-weighted heatmap** — Composite score adds call frequency (20%) and queue pressure (10%) to existing formula
4. **Provable dead code** — Cross-reference `Knowledge.dead_code/2` with runtime trace. Zero static callers + zero runtime invocations = provably dead.
5. **True blast radius** — Filter `impact_map/3` results by runtime activity. Only count dependents that actually call the module.
6. **Merged endpoints**:
   - `GET /api/knowledge/heatmap?path=P&runtime=true&freshness=10` — runtime-weighted scores
   - `GET /api/knowledge/dead_code?path=P&runtime=true` — provably dead (static + runtime)
   - `GET /api/knowledge/impact?path=P&module=X&runtime=true` — traffic-filtered blast radius

### Temporal Decay — Runtime Data Becomes Lies

Runtime data has a shelf life. If you ran a load test an hour ago, those edge weights (10,000 calls/sec) are no longer relevant to your current debugging session. Without decay, Giulia will give confident answers based on stale data — which is worse than no data at all.

**Implementation:**
- Every runtime edge weight is stored with `last_sampled_at` timestamp
- All runtime queries accept a `freshness` parameter (minutes, default: 10)
- Query logic: if `now - last_sampled_at > freshness`, the runtime weight is **excluded** from the response (treated as absent, not zero)
- Responses include a `data_age` field: *"Runtime data for this module is 3 minutes old"* vs *"No recent runtime data (last sample: 47 minutes ago, excluded)"*
- The Collector's rolling buffer naturally provides freshness — if Collector is running at 30s intervals, data is always <30s old for connected nodes

**The result:** *"I see this was a hot path 5 minutes ago, but it is currently idle"* — not *"this path handles 10,000 calls/sec"* based on a stale load test.

### Open questions (to resolve during Build 92)
- `:telemetry` vs `:erlang.trace`: telemetry is cooperative (app must emit), trace is universal but heavier. Build 92's kill switch makes trace safer — does that settle the question?
- Storage: should runtime edges live in the same libgraph (as edge labels) or a parallel ETS table keyed by `{source, target}`?

---

## Build Order & Dependencies

```
Build 91 (Architect Brief)     — no dependencies, start immediately
    │
    ▼
Build 92 (Runtime Sensor)     — depends on 91 (injects into brief + preflight)
    │
    ├──► Build 93 (Plan Validation) — independent, but benefits from 91+92
    │
    ▼
Build 94 (Runtime Graph)      — depends on 92 (needs Inspector + Collector + trace data)
```

## Verification Plan

After each build:

1. **Build 91**: `curl -s "http://localhost:4000/api/brief/architect?path=C:/Development/GitHub/Giulia" | python -m json.tool` — verify all sections populated, no nulls in core fields
2. **Build 92 — First Strike**:
   - `GET /api/runtime/pulse` — verify BEAM health for local node (memory, processes, schedulers)
   - `GET /api/runtime/top_processes?metric=reductions` — verify top 10 with PID, module, reductions
   - `GET /api/runtime/hot_spots` — verify PID → Module → Knowledge Graph fusion (must include complexity, centrality, zone)
   - `POST /api/runtime/connect` with a remote node — verify connection or clean `node_unreachable` error
2b. **Build 92 — Full**:
   - `GET /api/runtime/trace?module=Giulia.Knowledge.Store&duration=5000` — verify function call counts
   - `GET /api/runtime/history?last=5` — verify Collector is accumulating snapshots
   - `GET /api/runtime/alerts` — verify warning generation with duration
   - `POST /api/briefing/preflight` — verify `LIVE PERFORMANCE ALERT` appears for hot modules
3. **Build 93**: `POST /api/plan/validate` with a plan touching 2 red-zone modules — verify warning verdict; POST with a plan introducing a cycle — verify rejected verdict
4. **Build 94**:
   - `GET /api/knowledge/heatmap?runtime=true` — verify scores differ from static-only
   - `GET /api/knowledge/dead_code?runtime=true` — verify provable dead code list is subset of static dead code
5. **All builds**: `mix compile --all-warnings` clean, `mix test` green
6. Increment `@build` in `mix.exs` for each build (91, 92, 93, 94)

## Summary

| Build | New Modules | New Routes | Lines | Risk |
|-------|------------|------------|-------|------|
| 91 | `Intelligence.ArchitectBrief` | 1 | ~170 | Zero |
| 92 | `Runtime.Inspector`, `Runtime.Collector` | 8 | ~650 | Zero |
| 93 | `Intelligence.PlanValidator` | 1 | ~275 | Low |
| 94 | Runtime Graph integration | 3 (merged) | ~300 | Low |

Total: 6 new modules, 13 new routes, ~1,395 lines of new code. Build 92 is the largest — it's the live sensor that makes everything else smarter.
