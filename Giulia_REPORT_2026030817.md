# Giulia Self-Analysis Report

**Project**: Giulia (AI Development Agent)
**Build**: 132
**Date**: 2026-03-08 17:00 UTC
**Path**: D:/Development/GitHub/Giulia

---

## 1. Executive Summary

| Metric | Value |
|---|---|
| Source Files | 134 |
| Modules | 134 |
| Functions | 1,360 (968 public, 392 private) |
| Types | 57 |
| Specs | 511 / 968 public functions (52.8%) |
| Structs | 6 |
| Callbacks | 7 |
| Graph Vertices | 1,494 |
| Graph Edges | 1,818 |
| Connected Components | 412 |
| Circular Dependencies | 4 cycles |
| Behaviour Fractures | 0 |
| Orphan Specs | 0 |
| Dead Code | 1 function |

**Verdict**: Solid architecture with good spec coverage (52.8%). The 4 dependency cycles are all parent-child module splits (Store/Query, State/Counters) — structural, not architectural. Primary gap: 10 hub modules with inadequate spec/doc coverage (unprotected hubs).

---

## 2. Heatmap Zones

### Red Zone (score >= 60) — 2 modules

| Module | Score | Complexity | Centrality | Max Coupling | Tests? |
|---|---|---|---|---|---|
| Intelligence.SemanticIndex | 65 | 55 | 7 | 49 | No |
| Core.ProjectContext | 60 | 50 | 7 | 38 | No |

SemanticIndex is high due to Nx tensor operations (inherent complexity) and no dedicated test file. ProjectContext carries GenServer state management complexity and also lacks a dedicated test.

### Yellow Zone (score 30-59) — 45 modules

| Module | Score |
|---|---|
| Client.Renderer | 57 |
| Runtime.Inspector | 53 |
| Tools.RunTests | 52 |
| Knowledge.Store.Reader | 49 |
| Runtime.Collector | 48 |
| Client.Commands | 47 |
| Client.Output | 43 |
| Client.REPL | 43 |
| Knowledge.Metrics | 42 |
| Daemon.Routers.Knowledge | 42 |
| Tools.PatchFunction | 41 |
| StructuredOutput | 41 |
| Intelligence.Preflight | 40 |
| Core.ContextManager | 40 |
| Inference.Transaction | 39 |
| Knowledge.Behaviours | 38 |
| Tools.EditFile | 38 |
| Prompt.Builder | 37 |
| Knowledge.Insights | 37 |
| Context.Builder | 36 |
| Inference.Engine | 36 |
| AST.Analysis | 36 |
| Runtime.Profiler | 35 |
| Inference.RenameMFA | 35 |
| Inference.BulkReplace | 35 |
| Inference.Escalation | 35 |
| Knowledge.Topology | 34 |
| Inference.ResponseParser | 34 |
| Tools.WriteFunction | 34 |
| Tools.WriteFile | 33 |
| Inference.Verification | 33 |
| Utils.Diff | 33 |
| Context.Indexer | 32 |
| Core.PathSandbox | 32 |
| Core.PathMapper | 32 |
| Inference.Engine.Commit | 32 |
| Intelligence.ArchitectBrief | 32 |
| Intelligence.PlanValidator | 32 |
| Inference.ContextBuilder.Messages | 31 |
| AST.Extraction | 31 |
| Inference.Engine.Response | 31 |
| Inference.Orchestrator | 31 |
| Inference.ToolDispatch | 30 |
| Inference.ToolDispatch.Guards | 30 |
| Inference.Engine.Step | 30 |

### Green Zone (score < 30) — 87 modules

No action needed.

---

## 3. Top 5 Hubs

| Module | In-Degree | Out-Degree | Risk Profile |
|---|---|---|---|
| Context.Store | 35 | 3 | Pure hub — stable interface, everything depends on it |
| Tools.Registry | 32 | 0 | Pure hub — zero outbound deps, tool dispatch nexus |
| Inference.State | 17 | 3 | Pure hub — inference pipeline backbone |
| Knowledge.Store | 16 | 5 | Slight fan-out — graph analytics gateway |
| Core.PathSandbox | 14 | 0 | Pure hub — security primitive, zero dependencies |

---

## 4. Change Risk (Top 10)

| Rank | Module | Score | Key Driver |
|---|---|---|---|
| 1 | Context.Store | 2,701 | Extreme centrality (35) x 33 public functions |
| 2 | Inference.State | 1,729 | 56 functions x 17 dependents |
| 3 | Knowledge.Store | 1,494 | 34 functions x 16 dependents x moderate complexity |
| 4 | Tools.Registry | 1,292 | 32 dependents — highest in-degree after Store |
| 5 | Intelligence.SemanticIndex | 1,116 | Complexity 55, coupling 49 to Enum/Nx |
| 6 | Core.ProjectContext | 1,071 | Complexity 50, coupling 38, 25 functions |
| 7 | Inference.Transaction | 880 | 8 dependents x complexity 41 |
| 8 | Prompt.Builder | 840 | Complexity 57 (highest pure complexity) |
| 9 | Core.PathSandbox | 816 | 14 dependents — security boundary |
| 10 | Core.PathMapper | 806 | 11 dependents — path translation layer |

---

## 5. God Modules

| Module | Functions | Complexity | Score |
|---|---|---|---|
| AST.Extraction | 25 | 98 | 227 |
| Context.Store | 33 | 28 | 194 |
| Prompt.Builder | 23 | 57 | 155 |
| Intelligence.SemanticIndex | 24 | 55 | 155 |
| Tools.PatchFunction | 22 | 64 | 150 |
| Core.ProjectContext | 27 | 50 | 148 |
| Client.Renderer | 9 | 66 | 147 |
| Runtime.Collector | 22 | 55 | 147 |
| Tools.Registry | 12 | 19 | 146 |
| Inference.State | 56 | 19 | 145 |

**AST.Extraction** (score 227, fan-in 2): Highest complexity but only 2 dependents — safe refactoring target. Complexity is spread across parsing functions, not concentrated.

| Function | Arity | Cognitive Complexity |
|---|---|---|
| extract_docs | 1 | 7 |
| extract_moduledoc | 1 | 5 |
| extract_optional_pairs | 1 | 5 |

**Context.Store** (score 194, fan-in 35): High score driven by function count (33) and massive centrality. Already split into Store/Query/Formatter sub-modules in Build 128. Complexity per function is low — this is a flat API surface, not a refactoring target.

No functions with complexity >= 5 — complexity is spread thin across many small functions.

**Prompt.Builder** (score 155, fan-in 6): Template construction logic, moderate centrality.

| Function | Arity | Cognitive Complexity |
|---|---|---|
| find_relevant_ast | 2 | 8 |
| format_parameters | 1 | 5 |

**SemanticIndex** (score 155, fan-in 7): Nx tensor operations drive complexity. Inherent to the domain.

| Function | Arity | Cognitive Complexity |
|---|---|---|
| build_clusters | 2 | 7 |
| build_function_entries | 2 | 7 |
| build_module_entries | 2 | 5 |

**PatchFunction** (score 150, fan-in 0): Zero dependents — leaf module, safe to refactor freely.

| Function | Arity | Cognitive Complexity |
|---|---|---|
| extract_range | 1 | 6 |

**Client.Renderer** (score 147, fan-in 2): TUI rendering logic — complexity is presentation, not business logic.

| Function | Arity | Cognitive Complexity |
|---|---|---|
| colorize_diff_line_ansi | 1 | 10 |

**Runtime.Collector** (score 147, fan-in 5): GenServer with alert checking logic.

| Function | Arity | Cognitive Complexity |
|---|---|---|
| check_alerts | 2 | 13 |

`check_alerts/2` at complexity 13 is the hottest function — candidate for extraction into a dedicated AlertChecker module.

---

## 6. Blast Radius (Top 3 Risk Modules)

### Context.Store (change_risk rank #1)

**Depth 1** (direct dependents, 35 modules):
Knowledge.Insights.Impact, Knowledge.Insights, ContextBuilder.Helpers, Tools.GetFunction, Engine.Startup, Knowledge.Behaviours, Context.Builder, Inference.Engine, Inference.Transaction, Intelligence.ArchitectBrief, Routers.Index, Knowledge.Metrics, Inference.ContextBuilder, Engine.Commit, Knowledge.Topology, Intelligence.Preflight, Persistence.Loader, Tools.GetModuleInfo, Knowledge.Store, ContextBuilder.Preview, ContextBuilder.Messages, Inference.RenameMFA, Core.ProjectContext, Tools.WriteFunction, ToolDispatch.Executor, Prompt.Builder, Giulia, Context.Indexer, Tools.SearchCode, Tools.PatchFunction, Intelligence.SemanticIndex, Tools.LookupFunction, Context.Store.Query, Context.Store.Formatter, Daemon.Endpoint

**Depth 2** (transitive, 28 additional modules):
Inference.BulkReplace, ToolDispatch.Special, Intelligence.PlanValidator, Tools.TracePath, Tools.WriteFile, Routers.Intelligence, Routers.Search, Core.ContextManager, ToolDispatch.Staging, Tools.SearchMeaning, Knowledge.Analyzer, Inference.State, Routers.Knowledge, Tools.GetImpactMap, Inference.ToolDispatch, Routers.Transaction, Inference.Orchestrator, Tools.EditFile, Runtime.Inspector, Engine.Response, ToolDispatch.Guards, Intelligence.SurgicalBriefing, Engine.Step, ContextBuilder.Intervention, Engine.Helpers, ToolDispatch.Approval, Inference.Verification

**Total blast radius**: 63 modules affected (47% of codebase)
**Function-level edges**: 21 MFA-to-MFA call edges

**Cascading hub risk**: Depth-2 includes Knowledge.Store (hub #4, 16 dependents) and Inference.State (hub #3, 17 dependents) — modifying Context.Store could cascade through these hubs to their combined 33 additional dependents.

### Inference.State (change_risk rank #2)

**Depth 1** (direct dependents, 17 modules):
ContextBuilder.Intervention, ContextBuilder.Messages, Inference.Engine, Engine.Commit, Engine.Helpers, Engine.Response, Engine.Startup, Engine.Step, Inference.Orchestrator, State.Counters, State.Tracking, Inference.ToolDispatch, ToolDispatch.Approval, ToolDispatch.Executor, ToolDispatch.Guards, ToolDispatch.Special, ToolDispatch.Staging

**Depth 2** (transitive, 2 additional modules):
Inference.ContextBuilder, Inference.Pool

**Total blast radius**: 19 modules affected
**Function-level edges**: 1 MFA-to-MFA call edge (stuck_in_loop?/2)

Well-contained blast radius — State's dependents are almost exclusively the inference pipeline. Changes here don't leak into tools or daemon layers.

### Knowledge.Store (change_risk rank #3)

**Depth 1** (direct dependents, 16 modules):
Intelligence.PlanValidator, Tools.TracePath, Inference.Engine, Inference.Transaction, Intelligence.ArchitectBrief, Inference.ContextBuilder, Routers.Knowledge, Engine.Commit, Tools.GetImpactMap, Intelligence.Preflight, Persistence.Loader, Runtime.Inspector, Inference.RenameMFA, Prompt.Builder, Intelligence.SurgicalBriefing, Context.Indexer

**Depth 2** (transitive, 23 additional modules):
Inference.BulkReplace, ToolDispatch.Special, Routers.Runtime, Engine.Startup, Tools.WriteFile, Routers.Intelligence, Runtime.AutoConnect, ToolDispatch.Staging, Routers.Index, Inference.State, Inference.Orchestrator, Engine.Response, ContextBuilder.Messages, ToolDispatch.Guards, Core.ProjectContext, ToolDispatch.Executor, Giulia, Runtime.Collector, Engine.Step, Engine.Helpers, ToolDispatch.Approval, Tools.PatchFunction, Inference.Verification

**Total blast radius**: 39 modules affected (29% of codebase)
**Function-level edges**: 24 MFA-to-MFA call edges

**Cascading hub risk**: Depth-2 includes Inference.State (hub #3) — modifying Knowledge.Store could cascade through State to 17 inference pipeline modules.

---

## 7. Unprotected Hubs

| Module | In-Degree | Spec Coverage | Doc Coverage | Severity |
|---|---|---|---|---|
| Context.Store | 35 | 45% (15/33) | 42% | Red |
| Inference.State | 17 | 34% (19/56) | 4% | Red |
| Knowledge.Store | 16 | 32% (11/34) | 15% | Red |
| Inference.ContextBuilder | 11 | 20% (4/20) | 20% | Red |
| Daemon.SkillRouter | 9 | 33% (1/3) | 33% | Red |
| Intelligence.SemanticIndex | 7 | 10% (1/10) | 50% | Red |
| AST.Processor | 7 | 7% (2/30) | 97% | Red |
| Tools.RunTests | 7 | 17% (1/6) | 0% | Red |
| Inference.ToolDispatch | 3 | 33% (2/6) | 50% | Red |
| Knowledge.Analyzer | 3 | 0% (0/33) | 0% | Red |
| Tools.Registry | 32 | 70% (7/10) | 60% | Yellow |
| Engine.Helpers | 9 | 50% (2/4) | 100% | Yellow |
| Runtime.Collector | 5 | 58% (7/12) | 58% | Yellow |
| Context.Indexer | 5 | 73% (8/11) | 64% | Yellow |
| Core.ContextManager | 3 | 67% (6/9) | 56% | Yellow |
| Inference.Approval | 3 | 64% (7/11) | 36% | Yellow |
| Persistence.Store | 3 | 67% (6/9) | 67% | Yellow |
| Inference.Events | 3 | 71% (5/7) | 43% | Yellow |
| Persistence.Writer | 3 | 64% (7/11) | 64% | Yellow |

**Key insight**: 511 specs exist project-wide. The top 3 hubs (Context.Store, Inference.State, Knowledge.Store) account for 45 specs but have 123 public functions combined — these are the highest-leverage targets for spec coverage improvement. Knowledge.Analyzer at 0% specs with 33 functions is the worst offender but has low centrality (3), making it lower priority.

---

## 8. Coupling Analysis (Top 10 Project-Internal Pairs)

| Caller | Callee | Call Count | Distinct Functions |
|---|---|---|---|
| Inference.Engine | Inference.State | 39 | 15 |
| Inference.State.Counters | Inference.State | 31 | 1 |
| Inference.State.Tracking | Inference.State | 27 | 1 |
| Routers.Knowledge | Knowledge.Store | 24 | 21 |
| Engine.Response | Inference.State | 22 | 14 |
| Knowledge.Store.Reader | Knowledge.Analyzer | 23 | 23 |

Note: Most top coupling pairs (Enum, IO, String, Graph, Logger, MapSet, Nx) are stdlib — excluded per rules. The project-internal coupling above is largely by design:
- Engine ↔ State: The engine manipulates inference state — this is the core loop.
- State.Counters/Tracking → State: Sub-modules delegating back to parent — structural from the Build 128 split.
- Routers.Knowledge → Knowledge.Store: Router dispatches to store — clean separation.
- Store.Reader → Analyzer: Reader delegates compute to Analyzer — by design.

No concerning coupling patterns detected.

---

## 9. Dead Code

| Module | Function | Line |
|---|---|---|
| Daemon.SkillRouter | __skills__/0 | 55 |

**1 function out of 1,360 total (0.07%)**

Known false positive: `__skills__/0` in SkillRouter is the base module default that gets overridden by `@before_compile` in each router that `use SkillRouter`. The static analysis sees no callers at the source level, but the macro system injects the override at compile time.

---

## 10. Struct Lifecycle

| Struct | Defining Module | User Count | Logic Leaks | Leak Count |
|---|---|---|---|---|
| Inference.Transaction | Inference.Transaction | 1 | Inference.State | 1 |
| Inference.Approval | Inference.Approval | 0 | — | 0 |
| Inference.State | Inference.State | 0 | — | 0 |
| Core.PathSandbox | Core.PathSandbox | 0 | — | 0 |
| Core.ProjectContext | Core.ProjectContext | 0 | — | 0 |
| Inference.Pool | Inference.Pool | 0 | — | 0 |

Transaction struct is used by Inference.State (which embeds it as a field) — this is standard struct composition, not a concern. All other structs are well-contained within their defining modules.

---

## 11. Semantic Duplicates

3 clusters found at >= 85% similarity threshold.

**Cluster 1** (3 members, 92.5% avg similarity):
- SkillRouter.__using__/1
- SkillRouter.__before_compile__/1
- SkillRouter.__skills__/0

Structural similarity — these are macro metaprogramming functions that share AST manipulation patterns. Not duplication.

**Cluster 2** (2 members, 85.1% avg similarity):
- Runtime.Collector.watch_node/1
- Runtime.Collector.set_profile_callback/1

Both are simple GenServer.cast wrappers — structural similarity, not duplication.

**Cluster 3** (859 members, 5.9% avg similarity):
At 5.9% average similarity this cluster captures 859 of 1,360 functions — nearly the entire codebase. The clustering algorithm groups everything that shares basic Elixir function structure (def/defp, pattern match heads, pipe chains) into a single mega-cluster. This is a threshold artifact, not meaningful duplication.

---

## 12. Architecture Health

| Check | Status |
|---|---|
| Circular dependencies | 4 cycles found |
| Behaviour integrity | Consistent — 0 fractures |
| Orphan specs | 0 — clean |
| Dead code | 1 function (false positive) |

**Cycles detail:**
1. Client → Client.Commands → Client.Daemon → Client.REPL — Client sub-module cycle (parent delegates to children who reference parent)
2. Context.Store → Context.Store.Formatter → Context.Store.Query — Store sub-module cycle (Query/Formatter call back to Store for data access)
3. Inference.State → Inference.State.Counters → Inference.State.Tracking — State sub-module cycle (same pattern)
4. AST.Analysis → AST.Processor — Mutual dependency between analysis and processing

All 4 cycles are parent-child module splits where sub-modules delegate back to the parent. These are structural artifacts of the extraction pattern used in Builds 126-128, not architectural layering violations. The modules form cohesive units and could be collapsed back if the cycles are deemed problematic.

---

## 13. Runtime Health

| Metric | Value |
|---|---|
| Processes | 544 |
| Memory | 144.75 MB |
| Schedulers | 24 |
| Run Queue | 0 |
| Uptime | 9h 11m |
| ETS Tables | 69 |

**ETS Hot Tables:**

| Table | Size | Memory |
|---|---|---|
| EXLA.Defn.LockedCache | 7,004 | 7.21 MB |
| Context.Store | 524 | 2.91 MB |
| :giulia_knowledge_graphs | 4 | 1.99 MB |
| :giulia_runtime_snapshots | 600 | 1.56 MB |
| :code_server | 1,008 | 0.79 MB |

Run queue at 0 — no scheduler pressure. Memory at 144 MB is healthy for a BEAM application with ML model serving (EXLA cache is 7.2 MB for embedding model weights). No warnings.

---

## 14. Recommended Actions

### P0 (Blocking) — None

No blocking issues. Build compiles clean, no behaviour fractures, no orphan specs.

### P1 (High-Risk Gaps)

**P1-1: Document Inference.State (4% doc coverage, 56 public functions, 17 dependents)**
State is the #2 hub and the inference pipeline backbone — every engine, orchestrator, and tool dispatch module depends on it. 56 public functions with 2 documented means the most-touched API surface in the codebase is essentially undocumented. The 19 specs help Dialyzer but don't help contributors understand intent, valid states, or which functions are meant for external use vs internal plumbing. Expected impact: 54 new @doc entries, dramatically lower onboarding friction for the inference layer.

**P1-2: Add specs to Knowledge.Analyzer (0% coverage, 33 public functions, 3 dependents)**
Analyzer computes all graph metrics (heatmap, change_risk, dead_code, coupling). Its 33 functions have zero specs — any signature change breaks silently. Expected impact: 33 new specs, Dialyzer coverage for the entire analytics pipeline.

**P1-3: Add specs to AST.Processor (7% coverage, 30 public functions, 7 dependents)**
Processor is the AST manipulation core with 30 public functions and only 2 specs. It serves 7 downstream modules. Expected impact: 28 new specs, catch type mismatches in AST transformation pipeline.

### P2/P3 (Improvements)

**P2-1: Extract Runtime.Collector.check_alerts/2 (complexity 13)**
Highest single-function complexity in the codebase. Extract alert threshold logic into a dedicated AlertChecker module to improve testability.

**P2-2: Add test files for SemanticIndex and ProjectContext (red zone, score 65 and 60)**
The two red-zone modules both lack test files. Adding tests would drop their heatmap scores by 25 points each (to 40 and 35 — yellow zone), eliminating the red zone entirely.

**P2-3: Resolve parent-child cycles via behaviour or protocol boundaries**
The 4 cycles are benign but could be eliminated by having sub-modules depend on a shared behaviour instead of calling back to the parent module. Low urgency — the current pattern works but violates strict DAG topology.

---

Generated by Giulia v0.1.0-build.132 — D:/Development/GitHub/Giulia — 57 endpoints, 2026-03-08
