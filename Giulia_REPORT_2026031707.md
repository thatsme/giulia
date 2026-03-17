# Giulia Codebase Analysis Report

## Section 1: Executive Summary

| Metric | Value |
|---|---|
| Source files | 141 |
| Modules | 141 |
| Functions (total) | 1,472 |
| Types | 57 |
| Specs | 537 |
| Structs | 6 |
| Callbacks | 7 |
| Graph vertices | 1,613 (141 modules + 1,472 functions) |
| Graph edges | 1,977 |
| Connected components | 426 (*) |

(*) Component count is computed over the full module+function graph (1,613 vertices).
Most function-level vertices are leaves with a single edge to their parent module,
creating hundreds of trivial 1-2 vertex components. The module-only subgraph
(141 vertices, ~500 module-level edges) has far fewer components. The 426 number
reflects graph fragmentation at the function level, not architectural isolation.
| Circular dependencies | 5 |
| Behaviour fractures | 0 |
| Orphan specs | 0 |
| Dead code | 5 / 1,472 (0.34%) |
| Heatmap zones | 2 red, 52 yellow, 87 green |
| Unprotected hubs | 11 red, 8 yellow |

**Spec coverage**: 537 specs across the project. The `change_risk` endpoint reports
per-module public/private breakdowns. The project has significant spec gaps in hub
modules (see Section 7).

**Verdict**: Structurally healthy — near-zero dead code, zero orphan specs, zero behaviour
fractures. The single biggest gap is **spec coverage on hub modules**: the 5 most-depended-on
modules average 35% spec coverage. The 5 dependency cycles are all within tightly coupled
subsystems (client, store, state) and are architecturally acceptable.

---

## Section 2: Heatmap Zones

### Red Zone (score >= 60) — 2 modules

| Module | Score | Complexity | Centrality | Max Coupling | Tests? |
|---|---|---|---|---|---|
| Intelligence.SemanticIndex | 65 | 55 | 7 | 49 | No |
| Core.ProjectContext | 60 | 50 | 7 | 38 | No |

SemanticIndex is red primarily from high complexity (embedding pipeline) and high coupling
to Bumblebee/Nx internals. ProjectContext is the per-project GenServer holding AST, history,
constitution, and sandbox — complexity is inherent to its role.

### Yellow Zone (score 30-59) — 52 modules

Notable entries (score > 50):

| Module | Score | Key Driver |
|---|---|---|
| Client.Renderer | 57 | Complexity 66, no tests |
| Runtime.Inspector | 55 | Complexity 46, centrality 7 |
| Knowledge.Store.Reader | 53 | Complexity 54, coupling 51 |
| Tools.RunTests | 52 | Complexity 50, centrality 7 |
| Runtime.Collector | 50 | Complexity 55, centrality 6 |

The remaining 47 yellow modules score 30-49 — typical for a project of this size.

### Green Zone (score < 30) — 87 modules

87 modules in green (61.7% of codebase). Well-tested, low complexity, low coupling.

---

## Section 3: Top 5 Hubs

| Module | In-Degree | Out-Degree | Risk Profile |
|---|---|---|---|
| Context.Store | 36 | 3 | Pure hub — everything reads from ETS through this. Stable interface. |
| Tools.Registry | 32 | 0 | Pure hub — all 22 tools register here. Zero outbound deps. |
| Knowledge.Store | 18 | 7 | Bidirectional hub — reads from graph, serves to routers + intelligence. |
| Inference.State | 17 | 3 | Pure hub — inference engine state. All engine modules depend on it. |
| Inference.ContextBuilder | 11 | 8 | Bidirectional — builds context from multiple sources, used by engine. |

Tools.Registry (in-degree 32, out-degree 0) is the safest hub in the project — everything
depends on it but it depends on nothing.

---

## Section 4: Change Risk (Top 10)

**Formula**: `change_risk = centrality * function_count * (1 + complexity/100 + max_coupling/50)`

This is multiplicative — a module with high centrality AND high function count AND high
complexity scores exponentially higher. The gap between #1 (2,774) and #5 (227) is not a
bug in the formula; it reflects that data hubs compound risk across all three dimensions
while leaf modules only score on one.

| Rank | Module | Score | Centrality | Functions | Complexity | Coupling | Key Driver |
|---|---|---|---|---|---|---|---|
| 1 | Context.Store | 2,774 | 36 | 33 | 28 | 9 | Fan-in 36 x 33 functions = massive surface area |
| 2 | Knowledge.Store | 1,760 | 18 | 37 | 29 | 13 | 37 functions (highest non-State count) |
| 3 | Inference.State | 1,729 | 17 | 56 | 19 | 13 | 56 functions — highest function count in project |
| 4 | Tools.Registry | 1,292 | 32 | 10 | 19 | 8 | Fan-in 32 but only 10 functions — small API |
| 5 | AST.Extraction | 227 | 2 | 25 | 98 | 31 | Low centrality, high complexity (98) |
| 6 | Context.Store.Query | 197 | 1 | 15 | 30 | 25 | Sub-module of #1 |
| 7 | Prompt.Builder | 155 | 6 | 23 | 57 | 25 | LLM prompt construction |
| 8 | SemanticIndex | 155 | 7 | 24 | 55 | 49 | High coupling to Bumblebee/Nx |
| 9 | Knowledge.Store.Reader | 153 | 1 | 35 | 54 | 51 | 35 delegation functions |
| 10 | Tools.PatchFunction | 150 | 0 | 22 | 64 | 15 | Zero fan-in — safe to refactor |

The top 3 are all **data hubs** (ETS store, graph store, state struct). Their risk is driven
by surface area (many dependents x many functions), not by poor design.

---

## Section 5: God Modules

| Module | Functions | Complexity | Score | Assessment |
|---|---|---|---|---|
| AST.Extraction | 25 | 98 | 227 | Extraction logic for 10 AST node types. Complexity spread thin (max per-function: 7). Acceptable. |
| Context.Store | 33 | 28 | 197 | ETS facade — 33 public functions, 0 private. Pure delegation. Low per-function complexity (none >= 5). |
| Prompt.Builder | 23 | 57 | 155 | LLM prompt construction — tiered prompts, model detection, context building. Top function: find_relevant_ast/2 (8). |
| SemanticIndex | 24 | 55 | 155 | Embedding pipeline — model loading, indexing, search, clustering. Top function: build_clusters/2 (7). |
| Knowledge.Store | 41 | 29 | 153 | Graph facade — 37 public, 4 private. Delegates to Reader. Low per-function complexity (none >= 5). |
| Tools.PatchFunction | 22 | 64 | 150 | Sourceror-based function patching. Complex by nature. Zero fan-in — safe to refactor. |
| Runtime.Collector | 22 | 55 | 150 | Burst detection state machine. Complexity from alert thresholds + mode switching. |
| Core.ProjectContext | 27 | 50 | 148 | Per-project GenServer with AST, history, sandbox, constitution. One of the oldest modules. |
| Client.Renderer | 9 | 66 | 147 | Terminal output with ANSI coloring + diff rendering. Zero fan-in — leaf module, safe to refactor. |
| Tools.Registry | 12 | 19 | 146 | Tool discovery + dispatch. High score from fan-in (32), not complexity. |

Key insight: Context.Store (33 functions, score 197) and Knowledge.Store (41 functions, score 153)
are **pure facades** — zero or near-zero private functions, all delegation. They're god modules by
function count but not by complexity. Splitting them would add indirection without reducing risk.

---

## Section 6: Blast Radius (Top 3 Risk Modules)

### Context.Store (change_risk rank #1)

Depth 1 (direct dependents): Knowledge.Insights.Impact, Knowledge.Insights,
ContextBuilder.Helpers, Runtime.Profiler, Tools.GetFunction, Engine.Startup,
Knowledge.Behaviours, Context.Builder, Inference.Engine, Inference.Transaction,
ArchitectBrief, Routers.Index, Knowledge.Metrics, ContextBuilder,
Engine.Commit, Knowledge.Topology, Preflight, Persistence.Loader,
Tools.GetModuleInfo, Knowledge.Store, Daemon.Endpoint, and more.

Depth 2 (transitive): Persistence.Merkle, Persistence.Store,
Context.Store.Formatter, Context.Store.Query.

**Total blast radius: 30+ modules affected.**

Cascading hub risk: Knowledge.Store (hub #3) is a depth-1 dependent. Modifying
Context.Store could cascade through Knowledge.Store to its 18 dependents.

### Knowledge.Store (change_risk rank #2)

Depth 1 (direct): Runtime.Profiler, PlanValidator, Tools.TracePath,
Arcade.Indexer, Inference.Engine, Inference.Transaction, ArchitectBrief,
ContextBuilder, Routers.Knowledge, Engine.Commit, Tools.GetImpactMap,
Preflight, and more.

Depth 2 (transitive): Context.Store, Knowledge.Analyzer, Knowledge.Builder,
Knowledge.Store.Reader, Persistence.Writer, Storage.Arcade.Indexer, Version,
Context.Store.Formatter, Context.Store.Query, Knowledge.Behaviours,
Knowledge.Insights, Knowledge.Metrics, Knowledge.Topology, Persistence.Merkle,
Persistence.Store, Storage.Arcade.Client.

**Total blast radius: 28+ modules affected.**

Cascading hub risk: Context.Store (hub #1) is a depth-2 upstream dependency.

### Inference.State (change_risk rank #3)

Depth 1 (direct): ContextBuilder.Intervention, ContextBuilder.Messages,
Inference.Engine, Engine.Commit, Engine.Helpers, Engine.Response,
Engine.Startup, Engine.Step, Orchestrator, State.Counters, State.Tracking,
ToolDispatch, ToolDispatch.Approval, ToolDispatch.Executor,
ToolDispatch.Guards, ToolDispatch.Special, ToolDispatch.Staging.

Depth 2 (transitive): ContextBuilder, and more.

**Total blast radius: 20+ modules affected (entire inference subsystem).**

This is by design — Inference.State is the central data structure for the OODA loop.
All engine modules must read/write state. The risk is contained to the inference subsystem.

---

## Section 7: Unprotected Hubs

| Module | In-Degree | Spec Coverage | Doc Coverage | Severity |
|---|---|---|---|---|
| Context.Store | 36 | 45% | 42% | Red |
| Knowledge.Store | 18 | 30% | 14% | Red |
| Inference.State | 17 | 34% | 4% | Red |
| ContextBuilder | 11 | 20% | 20% | Red |
| SkillRouter | 9 | 33% | 33% | Red |
| SemanticIndex | 7 | 10% | 50% | Red |
| AST.Processor | 7 | 7% | 97% | Red |
| Tools.RunTests | 7 | 17% | 0% | Red |
| Engine.Helpers | 4 | 33% | 100% | Red |
| ToolDispatch | 3 | 33% | 50% | Red |
| Knowledge.Analyzer | 3 | 0% | 0% | Red |
| Tools.Registry | 32 | 70% | 60% | Yellow |
| Inference.Events | 11 | 71% | 43% | Yellow |
| Runtime.Collector | 6 | 58% | 58% | Yellow |
| Context.Indexer | 6 | 73% | 64% | Yellow |
| Persistence.Store | 5 | 67% | 67% | Yellow |
| ContextManager | 3 | 67% | 56% | Yellow |
| Inference.Approval | 3 | 64% | 36% | Yellow |
| Persistence.Writer | 3 | 64% | 64% | Yellow |

11 red-severity hubs. The worst: Knowledge.Analyzer has 33 public functions with 0 specs
and 0 docs — but it's a pure facade (delegates everything), so the specs/docs live on the
target modules (Topology, Metrics, etc).

The real concern: Inference.State (17 dependents, 56 public functions, 34% spec coverage,
4% doc coverage). This is the most-touched module in the inference engine with minimal
type safety.

---

## Section 8: Coupling Analysis (Top 10 Project-Internal Pairs)

Excluding stdlib (Enum, Map, String, IO, Logger, etc.):

| Caller | Callee | Distinct Functions |
|---|---|---|
| Knowledge.Store.Reader | Knowledge.Store (Graph) | via get_graph/1, direct ETS |
| Knowledge.Metrics | Knowledge.Topology | stats, centrality, dependents |
| Intelligence.Preflight | Knowledge.Store | heatmap, centrality, impact |
| Inference.Engine | Inference.State | 15+ state accessors/mutators |
| ContextBuilder | Context.Store | AST reads, module lookups |
| ToolDispatch.Guards | Inference.State | state checks (repeating?, max_failures?) |
| Inference.Transaction | Context.Store | backup/restore, overlay reads |
| ArchitectBrief | Context.Store | project summary, module details |
| Routers.Knowledge | Knowledge.Store | all 23 knowledge endpoints |
| Engine.Step | Inference.State | iteration checks, action recording |

The Inference.Engine <-> Inference.State coupling is the tightest in the project (15+ distinct
function calls). This is by design — State is a pure data module, Engine is the logic.
Splitting them would make the code worse, not better.

---

## Section 9: Dead Code

| Module | Function | Line |
|---|---|---|
| Daemon.SkillRouter | __skills__/0 | 55 |
| Storage.Arcade.Client | create_db/0 | 42 |
| Storage.Arcade.Client | list_projects/0 | 273 |
| Storage.Arcade.Consolidator | consolidate/0 | 36 |
| Storage.Arcade.Consolidator | status/0 | 41 |

5 functions out of 1,472 (0.34%).

- `__skills__/0` — false positive. Overridden at compile-time by `@before_compile`.
- `create_db/0` — called from test setup only (not detected by static analysis).
- `list_projects/0`, `consolidate/0`, `status/0` — public APIs for manual/future use. Not dead, just not called internally yet.

**Genuinely dead: 0.** All 5 are either false positives or intentional public APIs.

---

## Section 10: Struct Lifecycle

| Struct | Defining Module | User Count | Logic Leaks | Leak Count |
|---|---|---|---|---|
| Inference.Transaction | Inference.Transaction | 1 | Inference.State | 1 |
| Inference.State | Inference.State | 0 | - | 0 |
| Inference.Approval | Inference.Approval | 0 | - | 0 |
| Core.PathSandbox | Core.PathSandbox | 0 | - | 0 |
| Core.ProjectContext | Core.ProjectContext | 0 | - | 0 |
| Inference.Pool | Inference.Pool | 0 | - | 0 |

6 structs, all well-encapsulated. The only logic leak is Inference.State accessing
Transaction struct internals — acceptable, as State is the container for Transaction.

---

## Section 11: Semantic Duplicates

2 clusters returned by `/api/knowledge/duplicates?threshold=0.85`.

**Cluster 1** (3 members, 92.5% avg similarity): SkillRouter macro functions
(`__using__/1`, `__before_compile__/1`, `__skills__/0`). Structural similarity from
macro expansion — not duplication.

**Cluster 2** (928 members, 5.3% avg similarity): **Discarded — below threshold.**
The clustering algorithm returned this cluster despite its internal similarity (5.3%)
being far below the requested 85% threshold. This is a bug in the duplicate detection
endpoint — it should filter clusters whose `avg_similarity` falls below the requested
threshold. The 928 members represent nearly all functions in the project grouped into
a single junk cluster. Filed for fix in a future build.

**Genuinely duplicated logic: none detected.** Only 1 valid cluster (macro structural
similarity), no real code duplication.

---

## Section 12: Architecture Health

| Check | Status |
|---|---|
| Circular dependencies | 5 cycles found |
| Behaviour integrity | Consistent — 0 fractures |
| Orphan specs | 0 |
| Dead code | 5 functions (0 genuinely unused) |

**Cycles detail:**

1. Client -> Client.Commands -> Client.Daemon -> Client.REPL — CLI subsystem mutual deps. Acceptable for a REPL.
2. Context.Store -> Context.Store.Formatter -> Context.Store.Query — internal store triad. Acceptable for split modules sharing state.
3. Inference.State -> State.Counters -> State.Tracking — state module split. By design.
4. AST.Analysis -> AST.Processor — Processor delegates to Analysis, Analysis uses Processor. Could be broken.
5. Knowledge.Store -> Storage.Arcade.Indexer — Indexer snapshots graph from Store, Store triggers Indexer. Could be broken with an event/callback.

Cycles 4 and 5 are the only ones worth addressing. Neither is blocking.

---

## Section 13: Runtime Health

**BEAM Health:**

| Metric | Value |
|---|---|
| Processes | 544 |
| Memory | 133.82 MB |
| Schedulers | 24 |
| Run Queue | 0 |
| Uptime | 18h 20m |
| ETS Tables | 71 |
| Warnings | None |

**Top ETS Tables by Memory:**

| Table | Size | Memory |
|---|---|---|
| EXLA.Defn.LockedCache | 3,768 | 3.99 MB |
| :giulia_runtime_snapshots | 600 | 1.55 MB |
| Giulia.Context.Store | 144 | 0.99 MB |
| :code_server | 1,047 | 0.83 MB |
| :giulia_knowledge_graphs | 2 | 0.73 MB |

**Hot Spots:**

| Module | Reductions % | Memory | Assessment |
|---|---|---|---|
| Runtime.Collector | 89.5% | 10.4 MB | Expected — periodic snapshot collection every 5s |
| EXLA.Defn.Lock | 7.9% | 6.8 KB | Expected — EXLA lock manager |
| Giulia.Supervisor | 1.3% | 8.7 KB | Expected — supervisor bookkeeping |
| Task.Supervised | 1.1% | 1.0 MB | Expected — background tasks (101 processes) |

Runtime is healthy. 134 MB total memory, zero run queue pressure, no warnings.
The Collector dominates reductions because it polls every 5 seconds — this is by design,
not an anomaly.

---

## Section 14: Recommended Actions (Priority Order)

### P1: High-Risk Gaps

**1. Add specs to Inference.State** (56 public functions, 34% coverage, 17 dependents)

This is the most-touched module in the inference engine. Every engine step reads and mutates
state through these functions. Adding `@spec` to the remaining 37 unspecced functions would
catch type errors at compile time via Dialyzer. Expected effort: 2-3 hours (functions are
simple getters/setters).

**2. Break Knowledge.Store <-> Arcade.Indexer cycle** (cycle #5)

Store triggers Indexer on graph rebuild, Indexer reads from Store. Going public means
contributors will hit this cycle when modifying either module. Use a `{:graph_ready}`
message (already partially implemented) instead of a direct function call to decouple them.
Expected effort: 1 hour.

### P2: Improvement Opportunities

**3. Add specs to Knowledge.Analyzer** (33 public functions, 0% coverage, 3 dependents)

Pure facade with only 3 dependents — low risk, but 0% spec coverage looks bad in a
public repo. Every function is a one-line delegation, so specs can be copied from the
target modules (Topology, Metrics, Behaviours, Insights). Expected effort: 1 hour.

**4. Break AST.Analysis <-> AST.Processor cycle** (cycle #4)

Processor delegates to Analysis, but Analysis calls back into Processor for `parse/1`.
Extract the shared `parse/1` into a third module (e.g., `AST.Parser`) to break the cycle.
Low risk — both modules are well-tested.

**5. Split Client.Renderer (complexity 66, 9 functions)**

The highest per-function complexity in the project lives in a leaf module (zero fan-in).
Safe to refactor. Extract diff rendering and ANSI colorization into separate modules.

---

Generated by Giulia v0.1.0.137 -- /projects/Giulia -- 78 endpoints, 2026-03-17
