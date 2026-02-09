# Build 81-83: The Red Zone Refactor

## Overview

Heatmap (build 80) identified 6 red-zone modules. Orchestrator was already split (builds 74-79).
This plan targets the remaining 3 highest-impact refactoring candidates.

**Current state** (build 80):
- 65 modules, 991 vertices, 1181 edges
- Knowledge.Store: 2284 lines, 30 public + 58 private functions, coupling 155, score 89
- AST.Processor: 1221 lines, 26 public + 19 private functions, complexity 102, score 75
- Daemon.Endpoint: 1032 lines, 44 routes in 1 Plug.Router, complexity 69, score 68

---

## Build 81: Extract Giulia.Knowledge.Analyzer from Knowledge.Store

**The Problem**: Knowledge.Store is both a Librarian (GenServer managing `%Graph{}` state) and a Data Scientist (Dijkstra, heatmaps, centrality, coupling). Coupling score 155 — highest in the project.

**The Fix**: Extract all analytical/compute functions into `Giulia.Knowledge.Analyzer` — a library of pure functions that take a `%Graph{}` and return calculated metrics.

### What Stays in Store (GenServer + Graph Building)

**Public API (30 functions) — all stay as thin GenServer.call wrappers:**

| Function | Line | Role |
|----------|------|------|
| `start_link/1` | 52 | GenServer lifecycle |
| `init/1` | 290 | GenServer lifecycle |
| `handle_call/3` | 316 | GenServer dispatch — **changes to delegate to Analyzer** |
| `handle_cast/2` | 304 | GenServer dispatch |
| `rebuild/1` | 61 | State mutation |
| `rebuild/2` | 69 | State mutation |
| `graph/1` | 228 | State access |
| `add_semantic_edge/4` | 237 | State mutation |
| All 22 query functions | 77-283 | Stay as `GenServer.call` → unchanged public API |

**Private functions that stay (17 — graph construction + state):**

| Function | Line | Why stays |
|----------|------|-----------|
| `get_graph/2` | 295 | ETS state access |
| `put_graph/3` | 299 | ETS state mutation |
| `build_graph/1` | 494 | Graph construction orchestrator |
| `add_module_vertices/2` | 530 | Graph construction |
| `add_function_vertices/2` | 538 | Graph construction |
| `add_struct_vertices/2` | 556 | Graph construction |
| `add_behaviour_vertices/2` | 564 | Graph construction |
| `add_dependency_edges/3` | 580 | Graph construction |
| `add_implements_edges/3` | 601 | Graph construction |
| `add_xref_edges/1` | 627 | Graph construction |
| `find_beam_directory/0` | 640 | Graph construction helper |
| `run_xref_analysis/2` | 654 | Graph construction helper |
| `add_module_call_edges/2` | 689 | Graph construction |
| `add_function_call_edges/3` | 708 | Graph construction (Pass 4) |
| `extract_calls_per_function/6` | 747 | Pass 4 helper |
| `extract_calls_from_body/4` | 790 | Pass 4 helper |
| `collect_behaviour_callbacks/2` | 1231 | Graph construction helper |

### What Moves to Analyzer (41 private → public)

All `compute_*` functions and their helpers. These are **pure functions** — they take `graph`, `all_modules`, or `project_path` and return data. No state mutation.

**Core Analytics (become `Analyzer.compute_*`):**

| Function | Line | Description |
|----------|------|-------------|
| `compute_stats/1` | 2244 | Graph vertex/edge/component counts |
| `compute_centrality/2` | 958 | In-degree, out-degree for a module |
| `compute_dependents/2` | 1033 | Downstream consumers |
| `compute_dependencies/2` | 1043 | Upstream dependencies |
| `compute_impact_map/3` | 841 | Reachable modules at depth N |
| `compute_trace_path/3` | 1018 | Dijkstra shortest path |
| `compute_dead_code/2` | 1165 | Uncalled functions |
| `compute_cycles/1` | 1634 | Strongly connected components |
| `compute_god_modules/2` | 1670 | Weighted refactoring targets |
| `compute_orphan_specs/1` | 1729 | Specs without matching functions |
| `compute_fan_in_out/2` | 1327 | Fan-in/fan-out ranking |
| `compute_coupling/2` | 1366 | Module pair coupling scores |
| `compute_api_surface/1` | 1434 | Public/private ratio |
| `compute_change_risk/2` | 1472 | Composite risk score |
| `compute_behaviour_integrity/3` | 1057 | Callback contract checking |
| `compute_all_behaviours/2` | 1113 | All behaviour contract checks |
| `compute_test_targets/3` | 972 | Test file suggestions |

**Oracle Functions (build 80 — also move):**

| Function | Line | Description |
|----------|------|-------------|
| `compute_logic_flow/4` | 1769 | Dijkstra between MFA vertices |
| `compute_style_oracle/3` | 1831 | Exemplar functions with quality gate |
| `compute_pre_impact_check/3` | 1900 | Rename/remove risk analysis |
| `compute_heatmap/2` | 2137 | Composite health scoring |

**Helpers that move with their compute functions:**

| Function | Line | Used by |
|----------|------|---------|
| `collect_reachable/4` | 914 | `compute_impact_map` |
| `do_collect/7` | 919 | `collect_reachable` |
| `get_function_edges/2` | 943 | `collect_reachable` |
| `fuzzy_score/2` | 886 | `compute_impact_map` |
| `last_segment_match?/2` | 898 | `fuzzy_score` |
| `segments_overlap?/2` | 906 | `fuzzy_score` |
| `module_to_test_path/2` | 1006 | `compute_test_targets` |
| `collect_all_calls/1` | 1249 | `compute_dead_code` |
| `called_with_any_arity?/2` | 1312 | `compute_dead_code` |
| `build_coupling_map/1` | 1577 | `compute_coupling`, `compute_heatmap` |
| `enrich_mfa_vertex/2` | 1789 | `compute_logic_flow` |
| `parse_mfa_vertex/1` | 1818 | `enrich_mfa_vertex` |
| `check_rename_function/5` | 1921 | `compute_pre_impact_check` |
| `check_remove_function/4` | 1968 | `compute_pre_impact_check` |
| `check_rename_module/4` | 2027 | `compute_pre_impact_check` |
| `build_phases/3` | 2069 | Pre-impact check helpers |
| `compute_impact_risk/4` | 2098 | Pre-impact check helpers |
| `risk_level/1` | 2110 | `compute_impact_risk` |
| `build_hub_warnings/2` | 2114 | Pre-impact check helpers |
| `parse_func_target/1` | 2126 | `compute_pre_impact_check` |

### The Wiring Change

**Before** (handle_call in Store):
```elixir
def handle_call({:centrality, path, module}, _from, state) do
  {graph, _} = get_graph(state, path)
  {:reply, compute_centrality(graph, module), state}
end
```

**After** (handle_call delegates to Analyzer):
```elixir
def handle_call({:centrality, path, module}, _from, state) do
  {graph, _} = get_graph(state, path)
  {:reply, Analyzer.centrality(graph, module), state}
end
```

### Callers (10 modules — ZERO changes needed)

The public API on `Giulia.Knowledge.Store` doesn't change. All 10 dependents continue calling `Knowledge.Store.centrality/2`, `Knowledge.Store.dependents/2`, etc. The delegation to Analyzer is internal.

| Caller | Calls |
|--------|-------|
| Giulia.Daemon.Endpoint | 19 distinct functions |
| Giulia.Inference.Orchestrator | via impact/centrality |
| Giulia.Inference.RenameMFA | via dependents/impact |
| Giulia.Inference.Transaction | via integrity |
| Giulia.Intelligence.Preflight | via centrality/change_risk/impact |
| Giulia.Intelligence.SurgicalBriefing | via centrality/dependents |
| Giulia.Prompt.Builder | via stats |
| Giulia.Tools.GetImpactMap | via impact_map |
| Giulia.Tools.TracePath | via trace_path |
| Giulia.Context.Indexer | via rebuild |

### New File

`lib/giulia/knowledge/analyzer.ex` — ~1400 lines (all 41 functions, made public).

### Expected Impact

| Metric | Before | After |
|--------|--------|-------|
| Store lines | 2284 | ~900 |
| Store private functions | 58 | 17 |
| Store coupling (Enum calls) | 155 | ~30 |
| Analyzer lines | — | ~1400 |
| Analyzer coupling | — | ~125 (pure functions, acceptable) |
| External caller changes | — | 0 |

### Verification

```bash
docker compose build && docker compose up -d
curl -s http://localhost:4000/health  # v0.1.0.81

# Re-scan + verify graph integrity
curl -s -X POST http://localhost:4000/api/index/scan \
  -H "Content-Type: application/json" -d '{"path":"C:/Development/GitHub/Giulia"}'
curl -s "http://localhost:4000/api/knowledge/stats?path=C:/Development/GitHub/Giulia"
# Edge count should remain 1181

# Spot-check all endpoints still work
curl -s "http://localhost:4000/api/knowledge/heatmap?path=C:/Development/GitHub/Giulia"
curl -s "http://localhost:4000/api/knowledge/centrality?path=C:/Development/GitHub/Giulia&module=Giulia.Knowledge.Store"
curl -s "http://localhost:4000/api/knowledge/logic_flow?path=C:/Development/GitHub/Giulia&from=Giulia.Context.Indexer.scan/1&to=Giulia.Context.Store.put_ast/3"

# Store should drop from red (89) to yellow range (~35-40)
```

---

## Build 82: Split Giulia.AST.Processor into Reader/Writer/Metrics

**The Problem**: AST.Processor does 4 different jobs — Parsing, Slicing, Patching, and Metric Estimation. Complexity 102. All 5 dependents import everything even if they only need one capability.

**The Fix**: Split into 3 focused modules. Processor becomes a thin facade (optional — callers can import sub-modules directly).

### Module Split

#### Giulia.AST.Reader (parse + slice + extract — ~800 lines)

Reading and understanding code. Pure functions, no side effects.

**Public functions that move here:**

| Function | Line | Category |
|----------|------|----------|
| `parse/1` | 156 | Parsing |
| `parse_file/1` | 167 | Parsing |
| `analyze/2` | 182 | Analysis |
| `analyze_file/1` | 244 | Analysis |
| `extract_modules/1` | 255 | Extraction |
| `extract_functions/1` | 361 | Extraction |
| `extract_imports/1` | 424 | Extraction |
| `extract_types/1` | 529 | Extraction |
| `extract_specs/1` | 581 | Extraction |
| `extract_callbacks/1` | 632 | Extraction |
| `extract_structs/1` | 671 | Extraction |
| `extract_docs/1` | 740 | Extraction |
| `extract_moduledoc/1` | 797 | Extraction |
| `slice_function/3` | 1015 | Slicing |
| `slice_function_with_deps/3` | 1049 | Slicing |
| `slice_around_line/3` | 1072 | Slicing |
| `slice_for_error/3` | 1100 | Slicing |
| `get_function_range/3` | 928 | Slicing helper |
| `summarize/1` | 961 | Summary |
| `detailed_summary/1` | 979 | Summary |
| `debug_file/1` | 98 | Debug |
| `test_extraction/0` | 49 | Debug |

**Private helpers that move:**
- `extract_module_info/1` (L296), `safe_extract_module_info/1` (L285)
- `extract_function_info/1` (L396), `safe_extract_function_info/1` (L383), `build_function_info/4` (L410)
- `extract_import_info/1` (L461), `safe_extract_import_info/1` (L443)
- `extract_type_info/1` (L547)
- `extract_spec_info/1` (L599)
- `extract_callback_info/1` (L650)
- `extract_struct_fields/1` (L714)
- `extract_moduledoc_from_ast/1` (L338), `extract_moduledoc_from_body/1` (L323)
- `find_function_ast/3` (L1136), `find_function_at_line/2` (L1159)
- `get_end_line/2` (L1196), `get_line_range/1` (L1182)
- `safe_count_lines/1` (L234)

#### Giulia.AST.Writer (patch + insert — ~100 lines)

Modifying code. Side-effect-capable (takes AST, returns modified AST/source).

| Function | Line | Category |
|----------|------|----------|
| `patch_function/4` | 875 | Patching |
| `insert_function/3` | 902 | Insertion |

These two rely on `find_function_ast/3` from Reader — they'll call `AST.Reader.find_function_ast/3` (made public, or kept as shared utility).

#### Giulia.AST.Metrics (complexity + counting — ~200 lines)

Measuring code quality. Pure functions.

| Function | Line | Category |
|----------|------|----------|
| `estimate_complexity/1` | 840 | Complexity scoring |
| `count_lines/1` | 830 | Line counting |
| `extract_called_functions/1` | 1204 | Call graph helper |

#### Giulia.AST.Processor (facade — ~50 lines)

Thin delegation module for backward compatibility. Callers that `alias Giulia.AST.Processor` continue to work.

```elixir
defmodule Giulia.AST.Processor do
  defdelegate parse(source), to: Giulia.AST.Reader
  defdelegate parse_file(path), to: Giulia.AST.Reader
  defdelegate slice_function(source, module, func), to: Giulia.AST.Reader
  defdelegate patch_function(source, module, func, new_body), to: Giulia.AST.Writer
  defdelegate insert_function(source, module, code), to: Giulia.AST.Writer
  defdelegate estimate_complexity(source), to: Giulia.AST.Metrics
  defdelegate count_lines(source), to: Giulia.AST.Metrics
  # ... all 26 public functions delegated
end
```

### Callers (5 modules)

| Caller | Functions Used | Should Import |
|--------|---------------|---------------|
| Giulia.Context.Indexer | parse_file, analyze, extract_*, summarize | AST.Reader |
| Giulia.Knowledge.Store | estimate_complexity, slice_function, get_function_range | AST.Reader + AST.Metrics |
| Giulia.Tools.GetContext | slice_around_line, slice_for_error | AST.Reader |
| Giulia.Tools.GetFunction | slice_function, get_function_range | AST.Reader |
| Giulia.Tools.LookupFunction | slice_function | AST.Reader |

**Migration path**: Keep the Processor facade so nothing breaks. Callers can migrate to direct imports over time. No rush.

### Type Definitions

The 11 types (`ast/0`, `parse_result/0`, `file_info/0`, etc.) move to `AST.Reader` since they describe parsed data. Processor re-exports them via `@type` aliases.

### Expected Impact

| Metric | Before | After |
|--------|--------|-------|
| Processor lines | 1221 | ~50 (facade) |
| Reader lines | — | ~800 |
| Writer lines | — | ~100 |
| Metrics lines | — | ~200 |
| Complexity (max) | 102 | ~60 (Reader), ~10 (Writer), ~30 (Metrics) |
| External caller changes | — | 0 (facade preserves API) |

### Verification

```bash
docker compose build && docker compose up -d
curl -s http://localhost:4000/health  # v0.1.0.82

# Re-scan — verify indexer still works (biggest AST.Reader consumer)
curl -s -X POST http://localhost:4000/api/index/scan \
  -H "Content-Type: application/json" -d '{"path":"C:/Development/GitHub/Giulia"}'

# Module count should increase by 3 (Reader, Writer, Metrics)
curl -s "http://localhost:4000/api/index/summary?path=C:/Development/GitHub/Giulia"

# Verify Knowledge.Store still works (uses estimate_complexity + slice_function)
curl -s "http://localhost:4000/api/knowledge/heatmap?path=C:/Development/GitHub/Giulia"
curl -s "http://localhost:4000/api/knowledge/style_oracle?path=C:/Development/GitHub/Giulia&q=error+handling&top_k=3"
```

---

## Build 83: Split Daemon.Endpoint into Pluggable Routers

**The Problem**: 44 routes in a single Plug.Router. Complexity 69. Every new endpoint makes it worse.

**The Fix**: Use `Plug.Router.forward/2` to delegate route groups to dedicated routers.

### Route Distribution (current)

| Prefix | Count | Lines |
|--------|-------|-------|
| `/api/knowledge/*` | 19 | 431-790 |
| `/api/index/*` | 6 | 134-195 |
| `/api/search/*` | 3 | 197-344 |
| `/api/transaction/*` | 3 | 374-428 |
| `/api/command/*` | 2 | 33-92 |
| `/api/approval/*` | 3 | 792-825 |
| `/api/intelligence/*` | 1 | 281-303 |
| `/api/briefing/*` | 1 | 305-332 |
| Core (`/health`, `/api/status`, `/api/ping`, `/api/init`, `/api/projects`, `/api/debug/*`, `/api/agent/*`) | 6 | scattered |
| **Total** | **44** | |

### New Router Modules

#### Giulia.Daemon.Routers.Knowledge (~360 lines, 19 routes)

The biggest win. All `/api/knowledge/*` routes.

```elixir
defmodule Giulia.Daemon.Routers.Knowledge do
  use Plug.Router
  plug :match
  plug :dispatch

  # All 19 knowledge routes: stats, dependents, dependencies,
  # centrality, impact, integrity, dead_code, cycles, god_modules,
  # orphan_specs, fan_in_out, coupling, api_surface, change_risk,
  # path, logic_flow, style_oracle, pre_impact_check, heatmap
end
```

#### Giulia.Daemon.Routers.Index (~80 lines, 6 routes)

All `/api/index/*` routes.

```elixir
defmodule Giulia.Daemon.Routers.Index do
  use Plug.Router
  plug :match
  plug :dispatch

  # modules, functions, module_details, summary, status, scan
end
```

#### Giulia.Daemon.Routers.Transaction (~60 lines, 3 routes)

All `/api/transaction/*` routes.

```elixir
defmodule Giulia.Daemon.Routers.Transaction do
  use Plug.Router
  plug :match
  plug :dispatch

  # enable, staged, rollback
end
```

### Main Endpoint After Split

```elixir
defmodule Giulia.Daemon.Endpoint do
  use Plug.Router

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :match
  plug :dispatch

  # Forwarded route groups (28 routes → 3 routers)
  forward "/api/knowledge", to: Giulia.Daemon.Routers.Knowledge
  forward "/api/index", to: Giulia.Daemon.Routers.Index
  forward "/api/transaction", to: Giulia.Daemon.Routers.Transaction

  # Remaining 16 routes stay here:
  # /health, /api/status, /api/ping, /api/init, /api/projects
  # /api/command/stream, /api/command
  # /api/search, /api/search/semantic, /api/search/semantic/status
  # /api/intelligence/briefing, /api/briefing/preflight
  # /api/approval/*, /api/approvals
  # /api/debug/paths, /api/agent/last_trace
end
```

### Shared Helpers

The private helper functions currently in Endpoint need to be accessible to sub-routers:

| Helper | Used by | Solution |
|--------|---------|----------|
| `send_json/3` | All routers | Move to `Giulia.Daemon.Helpers` |
| `resolve_project_path/1` | All routers | Move to `Giulia.Daemon.Helpers` |
| `extract_module_name/1` | Knowledge, Index | Move to `Giulia.Daemon.Helpers` |

Create `lib/giulia/daemon/helpers.ex` with these 3 functions as public.

### Plug.Parsers Note

`Plug.Parsers` must be configured in the main Endpoint (before `forward`). Sub-routers receive already-parsed `conn.body_params`. No need to re-add Plug.Parsers in sub-routers.

### Path Stripping

`forward "/api/knowledge"` strips the prefix. Inside `Routers.Knowledge`, routes become:
- `get "/stats"` (not `get "/api/knowledge/stats"`)
- `get "/centrality"` (not `get "/api/knowledge/centrality"`)
- etc.

### Expected Impact

| Metric | Before | After |
|--------|--------|-------|
| Endpoint lines | 1032 | ~450 (16 routes + forwards) |
| Endpoint routes | 44 | 16 |
| Knowledge router | — | ~360 lines, 19 routes |
| Index router | — | ~80 lines, 6 routes |
| Transaction router | — | ~60 lines, 3 routes |
| Helpers | — | ~30 lines |
| Complexity (Endpoint) | 69 | ~25 |

### Verification

```bash
docker compose build && docker compose up -d
curl -s http://localhost:4000/health  # v0.1.0.83

# Test forwarded routes
curl -s "http://localhost:4000/api/knowledge/stats?path=C:/Development/GitHub/Giulia"
curl -s "http://localhost:4000/api/index/summary?path=C:/Development/GitHub/Giulia"
curl -s "http://localhost:4000/api/transaction/staged?path=C:/Development/GitHub/Giulia"

# Test routes that stayed in main Endpoint
curl -s http://localhost:4000/api/status
curl -s "http://localhost:4000/api/search/semantic/status?path=C:/Development/GitHub/Giulia"

# Full endpoint regression — hit all 44 routes
```

---

## Execution Order

| Build | Module | Risk | Dependencies |
|-------|--------|------|--------------|
| 81 | Knowledge.Store → Analyzer | Medium | None — internal refactor, public API unchanged |
| 82 | AST.Processor → Reader/Writer/Metrics | Low | None — facade preserves all call sites |
| 83 | Daemon.Endpoint → Routers | Low | None — `forward` is additive, routes unchanged |

Each build is independent. They can be done in any order. But 81 first is recommended because Knowledge.Store has the highest coupling score (155) and the most to gain.

## Files Created

| Build | New File | Lines |
|-------|----------|-------|
| 81 | `lib/giulia/knowledge/analyzer.ex` | ~1400 |
| 82 | `lib/giulia/ast/reader.ex` | ~800 |
| 82 | `lib/giulia/ast/writer.ex` | ~100 |
| 82 | `lib/giulia/ast/metrics.ex` | ~200 |
| 83 | `lib/giulia/daemon/routers/knowledge.ex` | ~360 |
| 83 | `lib/giulia/daemon/routers/index.ex` | ~80 |
| 83 | `lib/giulia/daemon/routers/transaction.ex` | ~60 |
| 83 | `lib/giulia/daemon/helpers.ex` | ~30 |

## Files Modified

| Build | File | Change |
|-------|------|--------|
| 81 | `mix.exs` | `@build 80` → `@build 81` |
| 81 | `lib/giulia/knowledge/store.ex` | Remove 41 private functions, update handle_call to delegate to Analyzer |
| 82 | `mix.exs` | `@build 81` → `@build 82` |
| 82 | `lib/giulia/ast/processor.ex` | Replace with facade (defdelegate) |
| 83 | `mix.exs` | `@build 82` → `@build 83` |
| 83 | `lib/giulia/daemon/endpoint.ex` | Remove 28 routes, add 3 forward declarations, extract helpers |

## Projected Heatmap After All 3 Builds

| Module | Before | After | Zone Change |
|--------|--------|-------|-------------|
| Knowledge.Store | 89 (red) | ~35 (yellow) | RED → YELLOW |
| Knowledge.Analyzer | — | ~40 (yellow) | New, acceptable |
| AST.Processor | 75 (red) | ~10 (green) | RED → GREEN |
| AST.Reader | — | ~35 (yellow) | New, acceptable |
| AST.Writer | — | ~10 (green) | New, clean |
| AST.Metrics | — | ~15 (green) | New, clean |
| Daemon.Endpoint | 68 (red) | ~25 (green) | RED → GREEN |
| Routers.Knowledge | — | ~30 (yellow) | New, acceptable |

**Red zone count**: 6 → 3 (Orchestrator, Context.Store, Context.Indexer remain)
