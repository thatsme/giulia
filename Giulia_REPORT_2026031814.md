# Giulia Self-Analysis Report

**Project**: Giulia — Local-First AI Development Agent
**Build**: 140
**Date**: 2026-03-18 14:00 UTC
**Scan Path**: /projects/Giulia (141 files, cache: warm, merkle: 5ddd6c352976)

---

## Section 1: Executive Summary

| Metric | Value |
|---|---|
| Source Files | 141 |
| Modules | 141 |
| Functions (total) | 1,477 |
| Public Functions | 1,046 |
| Types | 57 |
| Specs | 740 (70.7% of public functions) |
| Structs | 6 |
| Callbacks | 7 |
| Graph Vertices | 1,618 |
| Graph Edges | 1,968 |
| Connected Components | 432 |
| Circular Dependencies | 3 cycles |
| Behaviour Fractures | 0 |
| Orphan Specs | 0 |
| Dead Code | 0 functions |
| Test Files | 92 (65.2% module coverage) |

**How this data was collected**: Giulia scans all `.ex` files under `lib/`, parses each with Sourceror (pure Elixir AST parser), extracts module/function/type/spec/struct/callback metadata, and stores it in ETS (`Context.Store`). The Knowledge Graph is built from import/alias/use/require relationships plus function-level call edges extracted via xref analysis of compiled BEAM files. All metrics are computed from this graph using `libgraph` (directed graph library). Spec coverage is calculated as `specs / public def count` (excluding defp, defmacro, defstruct, etc.).

**Verdict**: Structurally healthy codebase with strong spec coverage (70.7%) and zero dead code. Three circular dependency cycles and 31 untested modules are the primary gaps. Context.Store dominates risk with a 67-module blast radius.

---

## Section 2: Heatmap Zones

The heatmap scores each module 0-100 using a weighted formula:
- **Centrality** (30%): `min(in_degree / 15 * 100, 100)` — how many modules depend on this one
- **Complexity** (25%): `min(module_complexity / 200 * 100, 100)` — total control flow nodes in the file
- **Test coverage** (25%): 0 if test file exists, 100 if not — binary penalty
- **Max coupling** (20%): `min(max_coupling_to_any_module / 50 * 100, 100)` — tightest dependency

A module with no test file gets an automatic 25-point floor penalty regardless of other factors.

### Red Zone (score >= 60) — 2 modules

| Module | Score | Complexity | Centrality | Max Coupling | Tests? |
|---|---|---|---|---|---|
| Intelligence.SemanticIndex | 65 | 55 | 7 | 50 | No |
| Core.ProjectContext | 60 | 50 | 7 | 38 | No |

Both modules are pushed into red primarily by the 25-point test penalty. SemanticIndex also has high max coupling (50) to Enum due to heavy collection processing in its embedding pipeline. ProjectContext has moderate coupling (38) to GenServer — expected for a stateful per-project manager.

### Yellow Zone (score 30-59) — 53 modules

| Module | Score |
|---|---|
| Client.Renderer | 57 |
| Runtime.Inspector | 55 |
| Knowledge.Store.Reader | 53 |
| Tools.RunTests | 52 |
| Runtime.Collector | 50 |
| Client.Commands | 47 |
| Runtime.Profiler | 44 |
| Daemon.SkillRouter | 44 |
| Client.Output | 43 |
| Client.REPL | 43 |
| Daemon.Routers.Knowledge | 43 |
| Knowledge.Behaviours | 42 |
| Client.HTTP | 41 |
| Runtime.IngestStore | 40 |
| Tools.EditFile | 39 |
| Inference.State | 39 |
| Tools.PatchFunction | 39 |
| Core.PathSandbox | 38 |
| Context.Store | 38 |
| Knowledge.Store | 38 |
| Tools.WriteFunction | 37 |
| Inference.Engine.Response | 37 |
| Tools.CycleCheck | 35 |
| Inference.ToolDispatch.Special | 35 |
| Inference.ToolDispatch.Executor | 35 |
| Core.PathMapper | 35 |
| Inference.ContextBuilder | 35 |
| Tools.SearchCode | 35 |
| Tools.Registry | 35 |
| Client | 34 |
| Runtime.Observer | 34 |
| Inference.Engine.Commit | 34 |
| Inference.ToolDispatch.Staging | 33 |
| Intelligence.SurgicalBriefing | 33 |
| Provider.Gemini | 32 |
| Client.Daemon | 32 |
| Inference.Transaction | 32 |
| Daemon.Endpoint | 32 |
| Runtime.Monitor | 32 |
| Inference.ToolDispatch.Approval | 31 |
| Provider.LMStudio | 31 |
| Role | 31 |
| Provider.Groq | 31 |
| Provider.Anthropic | 31 |
| Daemon.Helpers | 31 |
| Inference.Engine.Startup | 31 |
| Tools.GetFunction | 30 |
| Tools.GetModuleInfo | 30 |
| Runtime.AutoConnect | 30 |
| Tools.ListFiles | 30 |
| Intelligence.EmbeddingServing | 30 |
| Tools.LookupFunction | 30 |
| Tools.GetImpactMap | 30 |

### Green Zone (score < 30) — 86 modules

86 modules scored below 30. These are well-factored, well-tested, or low-centrality modules requiring no immediate attention.

### Test Coverage Gap Analysis

92 test files exist for 141 modules (65.2% by file). 31 modules have no corresponding `_test.exs` file. They fall into 5 categories:

**Category 1: GenServer/runtime modules requiring daemon infrastructure**

| Module | Why Untested | Priority |
|---|---|---|
| Intelligence.SemanticIndex | Needs EmbeddingServing (EXLA/Nx model) loaded in BEAM | P1 — mock Nx.Serving |
| Core.ProjectContext | GenServer with file watchers, constitution, dynamic supervision | P1 — test with temp dirs |
| Runtime.Collector | Periodic GenServer, ETS ring buffer, burst detection state machine | P1 — test state transitions |
| Runtime.Inspector | Introspects BEAM VM via :erlang BIFs | P3 — wrap BIFs for testability |
| Runtime.Profiler | Depends on Collector snapshots and remote nodes | P3 — needs Collector mock |
| Runtime.Observer | Distributed Erlang node discovery | P3 — needs multi-node setup |
| Runtime.Monitor | SSE pub/sub GenServer, depends on Collector + AutoConnect | P3 — integration scope |
| Runtime.AutoConnect | Distributed Erlang node connection | P3 — needs multi-node setup |
| Runtime.IngestStore | ETS store tightly coupled to Collector | P3 — test with Collector |
| Intelligence.EmbeddingServing | Nx.Serving wrapper, returns :ignore if model unavailable | P3 — test :ignore path |

**Category 2: Client-side modules (HTTP client to daemon)**

| Module | Why Untested | Priority |
|---|---|---|
| Client | HTTP thin client entry point | P2 — mock HTTP via Req.Test |
| Client.Commands | CLI command dispatch | P2 — mock HTTP responses |
| Client.Renderer | Terminal output formatting | P2 — capture IO output |
| Client.Output | IO.puts wrappers for colors | P3 — trivial wrappers |
| Client.REPL | Interactive stdin/stdout loop | P3 — hard to unit-test |
| Client.HTTP | Req-based HTTP client | P2 — mock via Req.Test |
| Client.Daemon | Process lifecycle (start/stop) | P3 — needs daemon process |

**Category 3: Tool modules (standard interface, no individual execute test)**

| Module | Priority |
|---|---|
| Tools.EditFile | P2 — quick win |
| Tools.PatchFunction | P2 — quick win |
| Tools.WriteFunction | P2 — quick win |
| Tools.SearchCode | P2 — quick win |
| Tools.CycleCheck | P2 — quick win |
| Tools.GetFunction | P2 — quick win |
| Tools.GetModuleInfo | P2 — quick win |
| Tools.ListFiles | P2 — quick win |
| Tools.LookupFunction | P2 — quick win |
| Tools.GetImpactMap | P2 — quick win |

All implement `Giulia.Tools.Registry` behaviour. A contract test validates the interface, but individual execute logic is untested. Each needs a basic test with a temp project directory — ~20 lines per file.

**Category 4: LLM provider modules (external service dependency)**

| Module | Priority |
|---|---|
| Provider.Gemini | P3 — mock HTTP response |
| Provider.LMStudio | P3 — mock HTTP response |
| Provider.Groq | P3 — mock HTTP response |
| Provider.Anthropic | P3 — mock HTTP response |

HTTP clients to external LLM APIs. Testable with fixture JSON responses via Req.Test or Bypass. Provider.Router (which dispatches to these) has tests.

**Priority summary for closing gaps:**
- **P1** (3 modules): SemanticIndex, ProjectContext, Collector — high risk, significant logic, testable with proper setup
- **P2** (13 modules): 10 tool modules (quick wins, ~20 lines each) + 3 Client modules (mock HTTP)
- **P3** (15 modules): Runtime.*, Provider.*, remaining Client.* — require more test infrastructure

No module is untestable. Every gap is a prioritization decision, not a technical limitation.

---

## Section 3: Top 5 Hubs

Hubs are identified by the Knowledge Graph's fan-in metric — the number of modules that depend on (import/alias/use) a given module. High fan-in means high blast radius: changing the module's interface breaks many consumers.

| Module | In-Degree | Out-Degree | Risk Profile |
|---|---|---|---|
| Context.Store | 36 | 3 | Pure hub — stable ETS interface, everything depends on it |
| Tools.Registry | 32 | 0 | Pure hub — zero outgoing dependencies, foundational service |
| Knowledge.Store | 18 | 6 | Primarily inbound — moderate orchestration of knowledge sub-modules |
| Inference.State | 17 | 3 | Pure hub — state container consumed by entire inference subsystem |
| Inference.ContextBuilder | 11 | 8 | Bidirectional hub — assembles context from many sources while serving inference pipeline |

---

## Section 4: Change Risk (Top 10)

Change risk uses a multiplicative formula: `centrality * function_count * (1 + complexity_norm + coupling_norm)`. This means a module with high centrality AND high function count AND high complexity scores exponentially higher — the risk compounds across dimensions.

| Rank | Module | Score | Pub/Priv | Centrality | Key Driver |
|---|---|---|---|---|---|
| 1 | Context.Store | 2,926 | 33/0 | 36 | Extreme centrality (36) x 33 public functions |
| 2 | Inference.State | 1,843 | 56/0 | 17 | 56 public functions (highest) x centrality 17 |
| 3 | Knowledge.Store | 1,760 | 37/4 | 18 | 41 total functions x centrality 18 |
| 4 | Tools.Registry | 1,292 | 10/2 | 32 | Centrality 32 dominates despite small function count |
| 5 | Intelligence.SemanticIndex | 1,125 | 10/14 | 7 | High complexity (55) + max coupling (50) amplify moderate centrality |
| 6 | Core.ProjectContext | 1,071 | 25/2 | 7 | Complexity (50) + 27 functions amplify centrality |
| 7 | Inference.ContextBuilder | 1,040 | 20/2 | 11 | Bidirectional hub (11 in, 8 out) with max coupling 28 |
| 8 | Inference.Transaction | 880 | 14/0 | 8 | Balanced across all factors |
| 9 | Prompt.Builder | 832 | 13/10 | 6 | Complexity (57) is primary contributor |
| 10 | Core.PathSandbox | 816 | 5/8 | 14 | Security-critical with 14 dependents |

---

## Section 5: God Modules

God modules are identified by a composite score of function count, complexity, and centrality. The endpoint ranks modules where concentrated logic creates maintenance risk.

| Module | Functions | Complexity | Centrality | Score |
|---|---|---|---|---|
| AST.Extraction | 25 | 98 | 2 | 227 |
| Context.Store | 33 | 28 | 36 | 197 |
| Knowledge.Store | 41 | 30 | 18 | 155 |
| Prompt.Builder | 23 | 57 | 6 | 155 |
| Intelligence.SemanticIndex | 24 | 55 | 7 | 155 |
| Tools.PatchFunction | 22 | 64 | 0 | 150 |
| Runtime.Collector | 22 | 55 | 6 | 150 |
| Core.ProjectContext | 27 | 50 | 7 | 148 |
| Client.Renderer | 9 | 66 | 2 | 147 |
| Tools.Registry | 12 | 19 | 32 | 146 |

**AST.Extraction** (score 227): Highest complexity at 98, but centrality is only 2 — a leaf module. Safe refactoring target. Complexity is spread thin (top function: `extract_docs/1` at cognitive complexity 7), not concentrated in any single function.

| Function | Arity | Cognitive Complexity |
|---|---|---|
| extract_docs | 1 | 7 |
| extract_moduledoc | 1 | 5 |
| extract_optional_pairs | 1 | 5 |

**Context.Store** (score 197): The #1 hub (36 dependents). Its 33 functions are thin ETS accessors and delegates to Query/Formatter sub-modules — per-function complexity is low. Splitting would be high-risk due to blast radius.

**Tools.PatchFunction** (score 150): Complexity 64 with zero centrality — pure leaf, ideal refactoring target. Only one function above cognitive complexity 5:

| Function | Arity | Cognitive Complexity |
|---|---|---|
| extract_range | 1 | 6 |

**Client.Renderer** (score 147): Only 9 functions but complexity 66 — concentrated in one rendering function:

| Function | Arity | Cognitive Complexity |
|---|---|---|
| colorize_diff_line_ansi | 1 | 10 |

**Prompt.Builder** (score 155): Complexity 57 with moderate centrality (6). Two functions concentrate the complexity:

| Function | Arity | Cognitive Complexity |
|---|---|---|
| find_relevant_ast | 2 | 8 |
| format_parameters | 1 | 5 |

**Tools.Registry** (score 146): High centrality (32) but low complexity (19) and only 12 functions. Not a true god module — score is driven by fan-in. Stable and well-tested.

---

## Section 6: Blast Radius (Top 3 Risk Modules)

Blast radius is computed by traversing the Knowledge Graph outward from a module to depth 2. Depth 1 = direct dependents. Depth 2 = modules that depend on depth-1 modules.

### Context.Store (change_risk rank #1)

**Depth 1 (direct dependents):** 36 modules — Knowledge.Store, Intelligence.SemanticIndex, Core.ProjectContext, Inference.Engine, Context.Indexer, Prompt.Builder, Intelligence.ArchitectBrief, Intelligence.Preflight, Inference.Transaction, Inference.ContextBuilder, Inference.Engine.Commit, Tools.SearchCode, Tools.PatchFunction, Tools.WriteFunction, Tools.LookupFunction, Tools.GetModuleInfo, Knowledge.Topology, Knowledge.Metrics, Knowledge.Behaviours, and 17 others.

**Depth 2 (transitive):** 31 additional modules — Inference.State, Inference.Orchestrator, Runtime.Monitor, Daemon.Routers.Knowledge, Inference.ToolDispatch, Runtime.Inspector, and 25 others.

**Total blast radius: 67 modules (47% of codebase)**
**Function-level edges: 21 MFA call edges**

Over 47% of all modules are within 2 hops of Context.Store. Any interface change here requires project-wide validation.

### Inference.State (change_risk rank #2)

**Depth 1 (direct dependents):** 17 modules — all within the Inference subsystem: Engine, Orchestrator, ToolDispatch, Engine.Helpers, Engine.Step, Engine.Response, Engine.Startup, Engine.Commit, ToolDispatch.Approval, ToolDispatch.Executor, ToolDispatch.Guards, ToolDispatch.Special, ToolDispatch.Staging, ContextBuilder.Intervention, ContextBuilder.Messages, State.Counters, State.Tracking.

**Depth 2 (transitive):** 2 additional modules — Inference.ContextBuilder, Inference.Pool.

**Total blast radius: 19 modules**
**Function-level edges: 1 MFA call edge**

Blast radius is contained within the Inference subsystem. The low MFA edge count (1) means dependents reference the struct fields rather than calling functions — struct shape changes are the primary risk vector.

### Knowledge.Store (change_risk rank #3)

**Depth 1 (direct dependents):** 18 modules — Intelligence.PlanValidator, Intelligence.ArchitectBrief, Intelligence.Preflight, Runtime.Inspector, Context.Indexer, Inference.Engine, Inference.Transaction, Inference.ContextBuilder, Inference.Engine.Commit, Storage.Arcade.Indexer, Persistence.Loader, Prompt.Builder, Intelligence.SurgicalBriefing, Runtime.Profiler, Tools.TracePath, Tools.GetImpactMap, Inference.RenameMFA, Daemon.Routers.Knowledge.

**Depth 2 (transitive):** 27 additional modules including Inference.State, Core.ProjectContext, Runtime.Collector, and 24 others.

**Total blast radius: 45 modules**
**Function-level edges: 28 MFA call edges**

**CASCADING HUB RISK**: Context.Store (hub #1, fan-in 36) appears at depth 2. Modifying Knowledge.Store could cascade through Context.Store to its 36 dependents, creating a chain reaction amplifying the effective blast radius beyond the 45 direct/transitive count.

---

## Section 7: Unprotected Hubs

Unprotected hubs are modules with high fan-in (many dependents) but low spec or doc coverage — the most dangerous combination: many consumers, no type contracts.

| Module | In-Degree | Spec Coverage | Severity |
|---|---|---|---|
| (none) | — | — | — |

**0 unprotected hubs (0 red, 0 yellow).** All hub modules have adequate spec coverage. This was achieved in Build 139-140 by adding 136 specs across 19 hub modules.

---

## Section 8: Coupling Analysis (Top 10 Pairs)

Coupling is measured by counting function calls between module pairs (extracted from compiled BEAM via xref). High coupling means one module is heavily dependent on another's API surface.

The top 10 pairs are all stdlib coupling (Enum, String, IO, Graph, GenServer), which is normal and healthy in Elixir:

| Caller | Callee | Call Count | Distinct Functions |
|---|---|---|---|
| Knowledge.Metrics | Enum | 54 | 15 |
| Knowledge.Analyzer | String | 52 | 1 |
| Knowledge.Store.Reader | String | 51 | 1 |
| Client.Renderer | IO | 51 | 3 |
| Intelligence.SemanticIndex | Enum | 50 | 15 |
| Knowledge.Topology | Graph | 46 | 14 |
| Intelligence.PlanValidator | Enum | 39 | 13 |
| Inference.Engine | Inference.State | 39 | 15 |
| Knowledge.Insights | Enum | 39 | 12 |
| Core.ProjectContext | GenServer | 38 | 5 |

The only project-internal pair in the top 10 is **Engine -> State** (39 calls, 15 functions). This is by design: Engine is the OODA orchestrator that drives State through its lifecycle. This is a standard GenServer + state module pattern — the coupling is intentional.

---

## Section 9: Dead Code

Dead code is detected by the Knowledge Graph: any function that exists as a vertex but has zero incoming call edges.

**0 functions detected as dead code out of 1,477 total (0.0%).**

The codebase is clean. Functions are removed when no longer needed rather than left as debris.

---

## Section 10: Struct Lifecycle

Struct lifecycle tracks where structs are defined, who uses them, and which modules reach into another module's struct fields ("logic leaks"). In Elixir, pattern matching on struct fields is idiomatic — a leak is a coupling metric, not a violation.

| Struct | Defining Module | User Count | Leak Count |
|---|---|---|---|
| Inference.Transaction | Inference.Transaction | 1 | 1 |
| Inference.Approval | Inference.Approval | 0 | 0 |
| Inference.State | Inference.State | 0 | 0 |
| Core.PathSandbox | Core.PathSandbox | 0 | 0 |
| Core.ProjectContext | Core.ProjectContext | 0 | 0 |
| Inference.Pool | Inference.Pool | 0 | 0 |

**Inference.Transaction** has 1 leak into Inference.State. This is expected — State embeds the Transaction struct as part of its lifecycle management. If Transaction's field names change, State would need updating. The compiler catches this automatically.

The remaining 5 structs are fully encapsulated. No "potentially unused struct" flags.

---

## Section 11: Semantic Duplicates

Semantic duplicate detection uses embedding vectors (384-dimensional, all-MiniLM-L6-v2) to find function pairs with high cosine similarity. Functions that look structurally similar cluster together.

**0 clusters found at >= 85% similarity threshold.**

No copy-paste patterns or structurally redundant implementations detected.

---

## Section 12: Architecture Health

| Check | Status |
|---|---|
| Circular dependencies | 3 cycles found (P0) |
| Behaviour integrity | Consistent — 0 fractures |
| Orphan specs | 0 |
| Dead code | 0 functions |

### Circular Dependency Details (P0)

Cycles are detected by finding strongly connected components in the Knowledge Graph (Tarjan's algorithm). A cycle means A depends on B depends on C depends on A — making it impossible to reason about changes in isolation.

**Cycle 1**: Client -> Client.Commands -> Client.Daemon -> Client.REPL
Lives within the Client escript subsystem. REPL needs Commands for dispatch, Commands needs Daemon for lifecycle, Daemon needs REPL for interactive mode. A shared types/behaviour module could break the loop.

**Cycle 2**: Context.Store -> Context.Store.Formatter -> Context.Store.Query
Internal to Store namespace. Formatter and Query reference Store for ETS access while Store delegates to them. Can be resolved by ensuring sub-modules call `all_asts/1` directly on ETS instead of through Store.

**Cycle 3**: Inference.State -> Inference.State.Counters -> Inference.State.Tracking
Internal to State namespace. Sub-modules reference the parent State type. Common pattern when extracting sub-concerns — the extracted pieces still need the parent's type definition.

---

## Section 13: Runtime Health

Runtime data is collected via `:erlang` BIFs (memory/0, system_info/1, statistics/1) and ETS introspection. Hot spots are identified by ranking all BEAM processes by reduction count (CPU proxy).

| Processes | Memory | Schedulers | Run Queue | Uptime | ETS Tables |
|---|---|---|---|---|---|
| 546 | 137.36 MB | 24 | 0 | ~3.3 hours | 71 |

**Run queue is 0** — no scheduler pressure. Memory at 137 MB is healthy for a daemon with full AST index, knowledge graph, embedding vectors (384-dim x 700+ entries), and ArcadeDB client loaded.

### ETS Memory (Top 5)

| Table | Size | Memory |
|---|---|---|
| EXLA.Defn.LockedCache | 3,784 entries | 4.01 MB |
| :giulia_runtime_snapshots | 600 entries | 1.55 MB |
| Context.Store | 144 entries | 1.03 MB |
| :code_server | 1,040 entries | 0.82 MB |
| :giulia_knowledge_graphs | 2 entries | 0.73 MB |

Total ETS memory: 9.5 MB across 71 tables. EXLA cache is the largest — expected for compiled Nx/EXLA tensor operations.

### Hot Spots

| Module | Reductions % | Memory | Notes |
|---|---|---|---|
| Runtime.Collector | 88.9% | 10.5 MB | Expected — periodic 5s sampling loop |
| Supervisor | 5.7% | 8.3 KB | Normal supervisor overhead |
| Persistence.Writer | 2.6% | 4.6 MB | Write-behind batching to CubDB |

No anomalous hot spots. Collector dominates reductions by design — it polls `:erlang.statistics` every 5 seconds across all watched nodes.

---

## Section 14: Recommended Actions (Priority Order)

### P0 — Blocking Issues

**1. Break 3 circular dependency cycles.**
Three cycles exist: Client subsystem (4 modules), Context.Store internals (3 modules), Inference.State internals (3 modules). The Client cycle spans distinct responsibilities and is the highest priority. The two internal cycles (Store, State) are contained within their namespaces and can be resolved by having sub-modules read ETS directly instead of calling back up to the parent module.

### P1 — High-Risk Gaps

**2. Add tests for 3 red/high-risk untested modules.**
SemanticIndex (red zone, score 65, change_risk #5), ProjectContext (red zone, score 60, change_risk #6), and Collector (yellow, score 50) have significant logic and zero test coverage. Each needs GenServer-level tests: SemanticIndex with mocked Nx.Serving, ProjectContext with temp directories, Collector with state transition assertions. Adding tests drops both red-zone modules to yellow (-25 points each).

### P2 — Improvement Opportunities

**3. Write execute tests for 10 tool modules.**
Quick wins: EditFile, PatchFunction, WriteFunction, SearchCode, CycleCheck, GetFunction, GetModuleInfo, ListFiles, LookupFunction, GetImpactMap. Each implements the Registry behaviour. A basic test per module (~20 lines) exercising `execute/2` with a temp project directory would cover the untested execute paths.

**4. Extract complexity from AST.Extraction (god module score 227, complexity 98).**
Highest god module score but only 2 dependents — safest high-value refactoring target. Complexity is spread across 25 functions (no single function above cognitive complexity 7), so extraction by AST node type (modules, functions, types, imports, docs) would create natural sub-modules.

**5. Monitor Context.Store blast radius (67 modules, change_risk #1 at 2,926).**
No immediate action — the module is well-specified and has a heatmap score of only 38. However, any future interface changes must be validated against its 67-module blast radius (47% of codebase). The module's thin-accessor design helps: most functions are single-line ETS lookups, reducing the likelihood of breaking changes.

---

Generated by Giulia v0.1.0-build.140 — /projects/Giulia — 57 endpoints, 2026-03-18
