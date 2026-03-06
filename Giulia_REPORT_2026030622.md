# Giulia Analysis Report

**Project**: Giulia v0.1.0 (Build 127)
**Date**: 2026-03-06 22:24 UTC
**Scan**: 127 source files, Knowledge Graph active (1,346 vertices, 1,694 edges)

---

## Section 1: Executive Summary

| Metric | Value |
|:-------|------:|
| Source Files | 127 |
| Modules | 127 |
| Functions | 1,219 |
| Types | 57 |
| Specs | 469 (38.5% coverage) |
| Structs | 6 |
| Callbacks | 7 |
| Graph Vertices | 1,346 |
| Graph Edges | 1,694 |
| Connected Components | 346 |
| Circular Dependencies | 4 cycles |
| Behaviour Fractures | 0 |
| Orphan Specs | 0 |
| Dead Code | 1 function (false positive) |

**Verdict**: Giulia is structurally healthy with clean behaviour contracts, zero orphan specs, and only 1 false-positive dead code hit. The single biggest gap is **spec coverage at 38.5%** — nearly two-thirds of public functions lack type specifications, with 7 red-severity unprotected hubs exposing critical interfaces without contracts.

---

## Section 2: Heatmap Zones

### Red Zone (>= 60) — 2 modules

| Module | Score | Complexity | Centrality | Max Coupling | Tests? |
|:-------|------:|-----------:|-----------:|-------------:|:------:|
| Intelligence.SemanticIndex | 65 | 55 | 7 | 49 | No |
| Core.ProjectContext | 63 | 75 | 7 | 38 | No |

Both red-zone modules share the same profile: moderate centrality but high complexity and no test file. The 25-point test penalty pushes them over the red threshold. Without that penalty, SemanticIndex would score ~40 (yellow) and ProjectContext ~38 (yellow). These are genuine test gaps — neither module has a corresponding `_test.exs` file.

### Yellow Zone (30-59) — 47 modules

| Module | Score | Module | Score |
|:-------|------:|:-------|------:|
| Client.Renderer | 57 | Runtime.Inspector | 54 |
| Tools.RunTests | 52 | Knowledge.Store.Reader | 49 |
| Client.Commands | 47 | Runtime.Collector | 44 |
| Client.Output | 43 | Client.REPL | 43 |
| Daemon.Routers.Knowledge | 43 | Daemon.SkillRouter | 43 |
| Knowledge.Behaviours | 42 | Client.HTTP | 41 |
| Core.PathSandbox | 38 | Knowledge.Store | 38 |
| Tools.PatchFunction | 38 | Inference.Engine.Response | 38 |
| Tools.EditFile | 37 | Context.Store | 37 |
| Inference.State | 37 | Tools.WriteFunction | 37 |
| Inference.ToolDispatch.Special | 36 | Tools.CycleCheck | 35 |
| Inference.ToolDispatch.Executor | 35 | Core.PathMapper | 35 |
| Inference.Engine.Commit | 35 | Tools.Registry | 35 |
| Client | 34 | Tools.SearchCode | 34 |
| Inference.ToolDispatch.Staging | 33 | Intelligence.SurgicalBriefing | 33 |
| Inference.ToolDispatch.Approval | 32 | Provider.Gemini | 32 |
| Client.Daemon | 32 | Inference.Transaction | 32 |
| Daemon.Endpoint | 32 | Prompt.Builder | 31 |
| Provider.LMStudio | 31 | Provider.Groq | 31 |
| Provider.Anthropic | 31 | Inference.Engine.Startup | 31 |
| Tools.GetFunction | 30 | Tools.GetModuleInfo | 30 |
| Tools.ListFiles | 30 | Intelligence.EmbeddingServing | 30 |
| Knowledge.Insights | 30 | Tools.LookupFunction | 30 |
| Tools.GetImpactMap | 30 | | |

### Green Zone (< 30) — 78 modules

78 modules in the green zone. Notable: AST.Extraction (score likely low despite 98 complexity because it has tests and low centrality), Persistence.Writer, Persistence.Loader, and all Daemon sub-routers except Knowledge.

---

## Section 3: Top 5 Hubs

| Module | In-Degree | Out-Degree | Risk Profile |
|:-------|----------:|-----------:|:-------------|
| Context.Store | 34 | 3 | Stable interface — everything depends on it. Pure data layer with 23 public functions, minimal outward deps. |
| Tools.Registry | 32 | 0 | Stable interface — pure hub with zero outward deps. All 12 tools depend on it for registration. |
| Inference.State | 17 | 3 | Stable interface — state container for the OODA loop. 19 public functions, all pure transforms. |
| Knowledge.Store | 16 | 5 | Bidirectional hub — 38 public functions delegate to Reader/Builder/Metrics. High blast radius in both directions. |
| Core.PathSandbox | 14 | 0 | Stable interface — security boundary. Zero outward deps, called by every file-touching tool. |

---

## Section 4: Change Risk (Top 10)

| Rank | Module | Score | Key Driver |
|-----:|:-------|------:|:-----------|
| 1 | Context.Store | 2,268 | Centrality (34 in-degree) x 23 public functions — pure hub surface area |
| 2 | Knowledge.Store | 1,494 | Centrality (16) x 38 total functions — largest API surface in the project |
| 3 | Core.ProjectContext | 1,332 | Complexity (75) x 39 functions — highest complexity GenServer |
| 4 | Tools.Registry | 1,292 | Centrality (32) — second-highest hub, but low complexity (19) limits risk |
| 5 | Intelligence.SemanticIndex | 1,116 | Complexity (55) x coupling (49 to single module) — Nx/Bumblebee integration |
| 6 | Inference.State | 1,026 | Centrality (17) x 19 functions — OODA state container |
| 7 | Prompt.Builder | 945 | Complexity (57) x coupling (26) — dynamic prompt assembly |
| 8 | Inference.Transaction | 880 | Complexity (41) x coupling (28) — staging/rollback logic |
| 9 | Core.PathSandbox | 816 | Centrality (14) — security boundary, many callers |
| 10 | Core.PathMapper | 806 | Centrality (11) x coupling (27) — Docker path translation |

---

## Section 5: God Modules

| Module | Functions | Complexity | Score |
|:-------|----------:|-----------:|------:|
| AST.Extraction | 25 | 98 | 227 |
| Core.ProjectContext | 39 | 75 | 210 |
| Context.Store | 23 | 28 | 181 |
| Runtime.Inspector | 22 | 67 | 171 |
| Knowledge.Insights | 20 | 71 | 165 |
| Prompt.Builder | 23 | 57 | 158 |
| Intelligence.SemanticIndex | 24 | 55 | 155 |
| Tools.PatchFunction | 22 | 64 | 150 |
| Client.Renderer | 9 | 66 | 147 |
| Tools.Registry | 12 | 19 | 146 |
| Knowledge.Store | 38 | 29 | 144 |
| Tools.RunTests | 22 | 49 | 141 |
| Daemon.Routers.Knowledge | 0 | 69 | 138 |
| Knowledge.Metrics | 17 | 55 | 130 |
| StructuredOutput | 14 | 48 | 128 |
| Core.ContextManager | 22 | 48 | 127 |
| Inference.Transaction | 14 | 41 | 120 |
| Intelligence.Preflight | 16 | 50 | 119 |
| Inference.State | 19 | 19 | 108 |
| Runtime.Collector | 15 | 39 | 105 |

**Commentary:**

- **AST.Extraction** (227): Highest complexity (98) but fan-in is only 7 — safe refactoring target. The 25 functions extract different AST node types (modules, functions, specs, types, etc.), so the complexity is structural, not accidental. Could split into sub-extractors but low urgency.
- **Core.ProjectContext** (210): 39 functions, highest complexity GenServer. Fan-in of 7 makes it a moderate risk. The `handle_call/3` is doing too much — a good candidate for splitting into focused callback modules.
- **Context.Store** (181): 23 public functions, low complexity (28). Fan-in of 34 makes it dangerous to modify despite low god-module score. Complexity is by design — thin ETS wrapper.
- **Knowledge.Store** (144): 38 functions but low complexity (29) — pure delegation layer. The function count is high because it mirrors Reader's full API. This is a facade, not a god module.
- **Daemon.Routers.Knowledge** (138): Reports 0 functions (Plug.Router macros aren't captured as functions) but 69 complexity from 23 route handlers. This is a single router handling all knowledge graph endpoints — intentional design from the Build 94 decoupling.
- **Client.Renderer** (147): Only 9 functions but 66 complexity — each function handles complex TUI rendering. Zero fan-in — pure leaf module, safe to refactor.

---

## Section 6: Blast Radius (Top 3 Risk Modules)

### Context.Store (change_risk rank #1)

**Depth 1 (direct dependents — 34 modules):**
Daemon.Endpoint, Knowledge.Insights, Inference.ContextBuilder.Helpers, Tools.GetFunction, Inference.Engine.Startup, Knowledge.Behaviours, Context.Store.Query, Context.Builder, Inference.Engine, Context.Store.Formatter, Inference.Transaction, Intelligence.ArchitectBrief, Daemon.Routers.Index, Knowledge.Metrics, Inference.ContextBuilder, Inference.Engine.Commit, Knowledge.Topology, Intelligence.Preflight, Persistence.Loader, Tools.GetModuleInfo, Knowledge.Store, Inference.ContextBuilder.Preview, Inference.ContextBuilder.Messages, Inference.RenameMFA, Core.ProjectContext, Tools.WriteFunction, Inference.ToolDispatch.Executor, Prompt.Builder, Giulia, Context.Indexer, Tools.SearchCode, Tools.PatchFunction, Intelligence.SemanticIndex, Tools.LookupFunction

**Depth 2 (transitive — 21 additional modules):**
Inference.BulkReplace, Inference.ToolDispatch.Special, Intelligence.PlanValidator, Tools.TracePath, Tools.WriteFile, Daemon.Routers.Intelligence, Daemon.Routers.Search, Core.ContextManager, Inference.ToolDispatch.Staging, Tools.SearchMeaning, Knowledge.Analyzer, Inference.State, Daemon.Routers.Knowledge, Tools.GetImpactMap, Inference.ToolDispatch, Daemon.Routers.Transaction, Inference.Orchestrator, Tools.EditFile, Inference.Engine.Response, Inference.Engine.Step, Inference.ToolDispatch.Approval

**Total blast radius: 55 modules affected**

**Cascading hub risk**: Knowledge.Store (Top 5 Hub, 21 degree) is a depth-1 dependent — modifying Context.Store could cascade through Knowledge.Store to its 16 dependents. Inference.State (Top 5 Hub, 20 degree) appears at depth 2.

### Knowledge.Store (change_risk rank #2)

**Depth 1 (direct dependents — 16 modules):**
Intelligence.PlanValidator, Tools.TracePath, Inference.Engine, Inference.Transaction, Intelligence.ArchitectBrief, Inference.ContextBuilder, Daemon.Routers.Knowledge, Inference.Engine.Commit, Tools.GetImpactMap, Intelligence.Preflight, Persistence.Loader, Runtime.Inspector, Inference.RenameMFA, Prompt.Builder, Intelligence.SurgicalBriefing, Context.Indexer

**Depth 2 (transitive — 22 additional modules):**
Inference.BulkReplace, Inference.ToolDispatch.Special, Daemon.Routers.Runtime, Inference.Engine.Startup, Tools.WriteFile, Daemon.Routers.Intelligence, Inference.ToolDispatch.Staging, Daemon.Routers.Index, Inference.State, Inference.Orchestrator, Inference.Engine.Response, Inference.ContextBuilder.Messages, Inference.ToolDispatch.Guards, Core.ProjectContext, Inference.ToolDispatch.Executor, Giulia, Runtime.Collector, Inference.Engine.Step, Inference.Engine.Helpers, Inference.ToolDispatch.Approval, Tools.PatchFunction, Inference.Verification

**Total blast radius: 38 modules affected**

**Cascading hub risk**: Context.Store (Top 5 Hub, 37 degree) is an upstream dependency — changes to Knowledge.Store that alter its Context.Store usage pattern could indirectly affect 34 modules.

### Core.ProjectContext (change_risk rank #3)

**Depth 1 (direct dependents — 7 modules):**
Core.ContextManager, Daemon.Routers.Transaction, Inference.ContextBuilder.Helpers, Inference.Engine, Inference.Orchestrator, Intelligence.ArchitectBrief, Tools.EditFile

**Depth 2 (transitive — 7 additional modules):**
Daemon.Endpoint, Daemon.Routers.Intelligence, Inference.ContextBuilder, Inference.ContextBuilder.Intervention, Inference.ContextBuilder.Messages, Inference.ContextBuilder.Preview, Inference.Pool

**Total blast radius: 14 modules affected**

ProjectContext has a smaller blast radius than its change_risk score suggests because its high score comes from complexity (75) rather than centrality (7). This makes it a safer refactoring target than Context.Store or Knowledge.Store.

---

## Section 7: Unprotected Hubs

### Red Severity (hub with zero or near-zero spec coverage)

| Module | In-Degree | Spec Coverage | Severity |
|:-------|----------:|:--------------|:---------|
| Knowledge.Store | 16 | Low | Red |
| Inference.ContextBuilder | 11 | Low | Red |
| Daemon.SkillRouter | 9 | Low | Red |
| Intelligence.SemanticIndex | 7 | Low | Red |
| Tools.RunTests | 7 | Low | Red |
| Inference.Engine.Helpers | 5 | Low | Red |
| Knowledge.Analyzer | 3 | Low | Red |

### Yellow Severity (partial spec coverage)

| Module | In-Degree | Spec Coverage | Severity |
|:-------|----------:|:--------------|:---------|
| Context.Store | 34 | Partial | Yellow |
| Tools.Registry | 32 | Partial | Yellow |
| Inference.Events | 12 | Partial | Yellow |
| AST.Processor | 7 | Partial | Yellow |
| Context.Indexer | 5 | Partial | Yellow |
| Runtime.Collector | 4 | Partial | Yellow |
| Core.ContextManager | 3 | Partial | Yellow |
| Inference.Approval | 3 | Partial | Yellow |
| Persistence.Store | 3 | Partial | Yellow |
| Inference.ToolDispatch | 3 | Partial | Yellow |
| Persistence.Writer | 3 | Partial | Yellow |

**Key insight**: 469 specs exist project-wide across 127 modules (38.5% of 1,219 functions). The specs are concentrated in leaf modules and tool definitions (`name/0`, `description/0`, `parameters/0`, `execute/2`). The critical hub layer (Context.Store, Knowledge.Store, Inference.ContextBuilder) — where specs matter most for contract enforcement — is underspecced.

---

## Section 8: Coupling Analysis (Top 10 Internal Pairs)

The coupling endpoint returns stdlib-dominated results. Only **1 internal pair** appears in the top 50:

| Caller | Callee | Call Count | Distinct Functions |
|:-------|:-------|----------:|-----------:|
| Daemon.Routers.Knowledge | Knowledge.Store | 24 | 21 |

This is **by design** — the Knowledge router is a thin HTTP layer that delegates every endpoint to Knowledge.Store. The 21 distinct function calls match the 23 knowledge graph endpoints (some share backing functions).

**Top stdlib coupling** (for reference, not actionable):

| Caller | Callee | Call Count |
|:-------|:-------|----------:|
| Knowledge.Insights | Enum | 61 |
| Knowledge.Metrics | Enum | 54 |
| Client.Renderer | IO | 51 |
| Intelligence.SemanticIndex | Enum | 49 |

All stdlib coupling is normal Elixir patterns — heavy Enum usage in data processing modules, IO in the TUI renderer.

---

## Section 9: Dead Code

| Module | Function | Line |
|:-------|:---------|-----:|
| Daemon.SkillRouter | `__skills__/0` | 55 |

**1 function out of 1,219 total (0.08%)**

This is a **known false positive**: `__skills__/0` is a default implementation injected by the `SkillRouter.__using__/1` macro. It's overridden at compile time via `@before_compile` in every module that `use SkillRouter`. The static analysis correctly sees it as "never called at the source level" but it exists as a fallback for modules that don't accumulate `@skill` attributes.

**Effective dead code: 0 functions.**

---

## Section 10: Struct Lifecycle

| Struct | Defining Module | User Count | Logic Leaks | Leak Count |
|:-------|:----------------|----------:|:------------|----------:|
| Inference.Transaction | Inference.Transaction | 1 | Inference.State | 1 |
| Inference.Approval | Inference.Approval | 0 | — | 0 |
| Inference.State | Inference.State | 0 | — | 0 |
| Core.PathSandbox | Core.PathSandbox | 0 | — | 0 |
| Core.ProjectContext | Core.ProjectContext | 0 | — | 0 |
| Inference.Pool | Inference.Pool | 0 | — | 0 |

**Analysis:**

- **Inference.Transaction** has 1 logic leak: `Inference.State` accesses the Transaction struct directly. This is expected — State embeds a Transaction struct as the `transaction` field and needs to read/update it during the OODA loop. This is shared data structure access, not an encapsulation violation.
- **5 structs with 0 external users**: All are well-encapsulated. Each struct is used only within its defining GenServer/module, which is the correct OTP pattern — state structs should be opaque to the outside world.
- **No potentially unused structs**: All 6 structs are actively used by their defining modules.

---

## Section 11: Semantic Duplicates

**2 clusters found at >= 80% similarity threshold**

### Cluster 1: SkillRouter macro functions (92.5% similarity, 3 members)

| Function |
|:---------|
| `Daemon.SkillRouter.__using__/1` |
| `Daemon.SkillRouter.__before_compile__/1` |
| `Daemon.SkillRouter.__skills__/0` |

**Structural similarity, not duplication** — these are macro-generated functions that share AST injection patterns (`quote do ... end`). They serve different purposes: `__using__` sets up the module, `__before_compile__` aggregates `@skill` attributes, `__skills__` returns the accumulated list.

### Cluster 2: Tool behaviour implementations (5.8% similarity, 725 members)

This massive cluster contains virtually every function in the project at very low similarity. This is a degenerate cluster — the similarity threshold is too low to be meaningful. It includes all tool `name/0`, `description/0`, `parameters/0`, `changeset/1`, and `execute/2` implementations.

**Structural similarity, not duplication** — these are behaviour callback implementations (`@behaviour Giulia.Tools.Registry`) that share the same function signatures by design.

---

## Section 12: Architecture Health

| Check | Status |
|:------|:-------|
| Circular Dependencies | 4 cycles found |
| Behaviour Integrity | Consistent — 0 fractures |
| Orphan Specs | 0 — Clean |
| Dead Code | 1 function (0 genuinely unused) |

### Circular Dependencies (P0)

| Cycle | Modules |
|:------|:--------|
| 1 | Client -> Client.Commands -> Client.Daemon -> Client.REPL |
| 2 | Context.Store -> Context.Store.Formatter -> Context.Store.Query |
| 3 | Inference.State -> Inference.State.Counters -> Inference.State.Tracking |
| 4 | AST.Analysis -> AST.Processor |

**Assessment:**

- **Cycles 2 & 3** are parent-submodule cycles: Store delegates to Query/Formatter which call back to Store for data access, and State delegates to Counters/Tracking which reference the parent struct. These are a common Elixir pattern for splitting large modules while keeping a unified API. Low risk — the cycle is between tightly-coupled siblings, not between separate domains.
- **Cycle 1** (Client cycle) is the CLI REPL loop: Client dispatches to Commands, Commands checks Daemon health, REPL loops back to Client. This is the interactive shell flow — circular by nature.
- **Cycle 4** (AST.Analysis <-> AST.Processor) is a utility cycle: Analysis uses Processor for parsing, Processor uses Analysis for... investigation needed. This is the most concerning cycle — two modules in the same domain shouldn't need bidirectional deps.

---

## Section 13: Runtime Health

### BEAM Health

| Metric | Value |
|:-------|------:|
| Processes | 547 |
| Memory | 136.2 MB |
| Schedulers | 24 |
| Run Queue | 0 |
| Uptime | 2,128 seconds (~35 min) |
| ETS Tables | 69 |
| ETS Memory | 10.6 MB |

**Run queue is 0** — no scheduler pressure. Memory at 136 MB is healthy for a project with embedded ML models (Bumblebee/EXLA).

### ETS Table Breakdown

| Table | Size | Memory |
|:------|-----:|-------:|
| EXLA.Defn.LockedCache | 2,952 | 3.2 MB |
| Context.Store | 432 | 2.9 MB |
| :giulia_knowledge_graphs | 6 | 2.4 MB |
| :code_server | 1,003 | 0.8 MB |
| :logger | 4 | 0.1 MB |

EXLA cache is the largest ETS consumer — expected with Bumblebee embedding models loaded.

### Hot Spots (Top 5 by CPU)

| Module | Reductions % | Memory | Assessment |
|:-------|------------:|-------:|:-----------|
| EXLA.Defn.Lock | 74.3% | 6.8 KB | Expected — EXLA compilation lock manager |
| Giulia.Supervisor | 12.9% | 6.8 KB | Expected — supervisor startup orchestration |
| Persistence.Writer | 7.4% | 2,124 KB | Expected — async write-behind with batching |
| Runtime.Collector | 3.4% | 225 KB | Expected — periodic BEAM telemetry collection |
| Context.Indexer | 2.0% | 3,437 KB | Expected — AST indexing (highest memory, holds parsed ASTs) |

All hot spots are expected infrastructure processes. No anomalous CPU or memory usage. Context.Indexer has the highest memory (3.4 MB) because it holds parsed AST data for 127 files.

---

## Section 14: Recommended Actions (Priority Order)

### P0 — Blocking Issues

**1. Break AST.Analysis <-> AST.Processor cycle**
Cycle 4 is the only non-structural circular dependency. AST.Analysis and AST.Processor are in the same domain but shouldn't have bidirectional deps. Investigate which direction can be eliminated — likely AST.Processor's dependency on Analysis can be replaced with a direct function call or extracted helper.

### P1 — High-Risk Gaps

**2. Add specs to Knowledge.Store (16 in-degree, red severity)**
Knowledge.Store has 38 public functions and is the gateway to all graph analysis. Every knowledge endpoint flows through it. Adding `@spec` to its public API would provide contract enforcement for 16 downstream consumers. Expected impact: would shift from red to green severity.

**3. Add specs to Inference.ContextBuilder (11 in-degree, red severity)**
ContextBuilder is the second-largest unprotected hub. Its 19-function API builds context for every inference request. Specs here would catch contract violations before they propagate through the OODA pipeline.

**4. Add test file for Core.ProjectContext (red zone, score 63, complexity 75)**
ProjectContext is the highest-complexity GenServer (75) with 39 functions and no test file. Adding `test/giulia/core/project_context_test.exs` would drop its heatmap score from 63 to ~38 (yellow) and provide regression protection for the module most likely to break during refactoring.

### P2/P3 — Improvements (capped at 3)

**5. Add test file for Intelligence.SemanticIndex (red zone, score 65)**
SemanticIndex has the highest heatmap score (65) driven by complexity (55), coupling (49), and no tests. A test file would drop it to ~40 (yellow). The Nx/Bumblebee integration makes this module fragile to dependency upgrades.

**6. Split Core.ProjectContext handle_call/3 (39 functions, complexity 75)**
ProjectContext's god-module score (210) is driven by a monolithic `handle_call/3` handling too many message types. Extracting constitution management, history management, and file operations into focused submodules would reduce complexity from 75 to ~25 per submodule. Fan-in of 7 keeps blast radius manageable.

**7. Raise spec coverage from 38.5% to 60% targeting hub modules**
Focus spec additions on the 11 yellow-severity unprotected hubs (Context.Store, Tools.Registry, Inference.Events, etc.). These modules collectively serve 100+ downstream dependents. Spec coverage at the hub layer provides maximum contract enforcement per spec written.

---

Generated by Giulia v0.1.0 (Build 127) — D:/Development/GitHub/Giulia — 20 endpoints queried, 2026-03-06
