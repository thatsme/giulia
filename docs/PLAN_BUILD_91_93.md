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

## Build 92: Runtime Proprioception

### Goal
Connect the static Knowledge Graph to the living BEAM node. New endpoint exposes process health, ETS memory, and message queue pressure.

### New file: `lib/giulia/runtime/inspector.ex`

Pure functional module. Queries `:erlang` and `:ets` introspection APIs:

```
Inspector.snapshot(project_path)
  → %{
      beam: %{processes: N, memory_mb: N, schedulers: N, uptime_seconds: N},
      ets: %{tables: N, total_memory_mb: N, largest: [...]},
      genservers: [
        %{name: "Knowledge.Store", message_queue: 0, reductions: N, memory_kb: N},
        %{name: "Inference.Pool", message_queue: 450, reductions: N, memory_kb: N},
        ...
      ],
      warnings: ["Inference.Pool message queue > 100: consider concurrency optimization"]
    }
```

Implementation details:
- `:erlang.memory/0` for BEAM memory breakdown
- `:erlang.system_info/1` for process count, schedulers
- `Process.list/0` + `:erlang.process_info/2` for named GenServer stats
- `:ets.all/0` + `:ets.info/2` for ETS table sizes
- Warning generation: message_queue > 100, memory > threshold, etc.
- Scope: **daemon self-health only** — this monitors Giulia's own processes

### New route in `lib/giulia/daemon/endpoint.ex`

```
GET /api/runtime/stats?path=P
```

### Optional: Inject into Architect Brief

Add a `runtime` section to the Build 91 brief so the architect automatically sees process health.

### Files touched
- **NEW**: `lib/giulia/runtime/inspector.ex` (~120 lines)
- **EDIT**: `lib/giulia/daemon/endpoint.ex` (add 1 route, ~15 lines)
- **EDIT**: `lib/giulia/intelligence/architect_brief.ex` (add optional runtime section, ~10 lines)

### Blast radius: Zero
Read-only BEAM introspection. No changes to existing modules.

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

### Files touched
- **NEW**: `lib/giulia/intelligence/plan_validator.ex` (~250 lines)
- **EDIT**: `lib/giulia/daemon/endpoint.ex` (add 1 route, ~25 lines)
- **EDIT**: `SKILL.md` + `docs/SKILL.md` (document the endpoint + expected usage)

### Blast radius: Low
Read-only consumption of Knowledge Graph. The cycle detection clone is a temporary in-memory copy — no mutation of the real graph.

---

## Build Order & Dependencies

```
Build 91 (Architect Brief)     — no dependencies, start immediately
    │
    ▼
Build 92 (Runtime Stats)       — depends on 91 (injects into brief)
    │
    ▼
Build 93 (Plan Validation)     — independent, but benefits from 91+92 context
```

## Verification Plan

After each build:

1. **Build 91**: `curl -s "http://localhost:4000/api/brief/architect?path=C:/Development/GitHub/Giulia" | python -m json.tool` — verify all sections populated, no nulls in core fields
2. **Build 92**: `curl -s "http://localhost:4000/api/runtime/stats?path=C:/Development/GitHub/Giulia"` — verify process list, ETS stats, memory figures
3. **Build 93**: `POST /api/plan/validate` with a plan touching 2 red-zone modules — verify warning verdict; POST with a plan introducing a cycle — verify rejected verdict
4. **All builds**: `mix compile --all-warnings` clean, `mix test` green
5. Increment `@build` in `mix.exs` for each build (91, 92, 93)

## Summary

| Build | New Module | New Route | Lines | Risk |
|-------|-----------|-----------|-------|------|
| 91 | `Intelligence.ArchitectBrief` | `GET /api/brief/architect` | ~170 | Zero |
| 92 | `Runtime.Inspector` | `GET /api/runtime/stats` | ~135 | Zero |
| 93 | `Intelligence.PlanValidator` | `POST /api/plan/validate` | ~275 | Low |

Total: 3 new modules, 3 new routes, ~580 lines of new code, 0 existing modules modified (beyond Endpoint routing).
