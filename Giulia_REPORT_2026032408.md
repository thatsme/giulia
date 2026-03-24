# Giulia Self-Analysis Report — Build 142

## Section 1: Executive Summary

| Metric | Value |
|---|---|
| Source files | 142 |
| Modules | 142 |
| Functions | 1,482 |
| Types | 59 |
| Specs | 744 |
| Structs | 6 |
| Callbacks | 7 |
| Graph vertices | 1,624 |
| Graph edges | 1,974 |
| Connected components | 432 |
| Circular dependencies | 3 cycles |
| Behaviour fractures | 0 — Consistent |
| Orphan specs | 0 |
| Dead code | 4 functions (0.3%) |
| Heatmap: Red / Yellow / Green | 1 / 49 / 92 |
| Test detection | 89/142 modules tested (62.7%) |

**Spec coverage**: 744 specs across the project. Exact public function count from api_surface shows heavy delegation patterns (many modules at 100% public ratio), indicating spec coverage is strong for interface modules.

**Verdict**: Healthy codebase with strong architectural discipline. The single biggest gap is the 3 circular dependency cycles — all in the client and delegation layers — which should be broken to maintain a clean DAG.

---

## Section 2: Heatmap Zones

### Red Zone (>= 60) — 1 module

| Module | Score | Complexity | Centrality | Max Coupling | Tests? |
|---|---|---|---|---|---|
| Intelligence.SemanticIndex | 65 | 55 | 7 | 50 | No |

SemanticIndex is red primarily due to high complexity (55) and max coupling (50). It has no dedicated test file — the embedding pipeline requires EXLA which only runs inside Docker, making it harder to unit test.

### Yellow Zone (30-59) — 49 modules

Top 15 by score:

| Module | Score |
|---|---|
| Client.Renderer | 57 |
| Tools.RunTests | 55 |
| Runtime.Collector | 50 |
| Client.Commands | 47 |
| Runtime.Profiler | 44 |
| Daemon.SkillRouter | 44 |
| Daemon.Routers.Knowledge | 43 |
| Client.REPL | 43 |
| Client.Output | 43 |
| Knowledge.Behaviours | 42 |
| Client.HTTP | 41 |
| Runtime.IngestStore | 40 |
| Tools.PatchFunction | 39 |
| Tools.EditFile | 39 |
| Inference.State | 39 |

34 additional modules scored between 30-38.

### Green Zone (< 30) — 92 modules

92 modules in green zone. Notable: Context.Store (score 20 despite 36 fan-in) and Tools.Registry (score 14 despite 32 fan-in) — both are well-tested hubs.

### Test Coverage Gap Analysis

**89/142 modules detected as tested (62.7%).** 53 modules lack test files.

**By-design (no unit test practical):**
- 10 Daemon Router modules (Routers.Knowledge, Routers.Runtime, etc.) — tested via integration tests in `test/integration/api_adversarial_test.exs`
- Daemon.Endpoint — HTTP pipeline, tested via router integration tests
- Application — OTP startup, tested implicitly
- Intelligence.EmbeddingServing — Bumblebee model loader, requires GPU/EXLA
- Intelligence.SemanticIndex — embedding pipeline, Docker-only
- Runtime.AutoConnect, Runtime.Observer — distributed Erlang, requires multi-node setup
- Storage.Arcade.* (Client, Indexer, Consolidator) — requires ArcadeDB container

**Actionable (should be tested):**
- Client.Renderer, Client.REPL, Client.Daemon — CLI rendering/REPL logic, testable with mock HTTP
- Prompt.Builder — complex prompt construction, high complexity (57), good test candidate
- Inference.Engine.* (Startup, Commit, Response, Step) — orchestrator sub-modules, testable in isolation
- Knowledge.Metrics — scoring logic, highly testable with fixture data

**Quick wins:** Prompt.Builder (pure function, no GenServer), Knowledge.Metrics (pure computation), Client.Renderer (IO capture).

---

## Section 3: Top 5 Hubs

| Module | In-Degree | Out-Degree | Risk Profile |
|---|---|---|---|
| Context.Store | 36 | 3 | Stable interface — the central ETS store, everything reads from it |
| Tools.Registry | 32 | 0 | Pure hub — zero outgoing deps, only consumed. Safe to extend, dangerous to change interface |
| Knowledge.Store | 18 | 6 | Bidirectional hub — both consumed and depends on Analyzer/Builder/Reader. Critical junction |
| Inference.State | 17 | 3 | Stable interface — OODA state struct, consumed by all engine modules |
| Daemon.Helpers | 14 | 1 | Stable utility — shared HTTP helpers for all routers |

---

## Section 4: Change Risk (Top 10)

| Rank | Module | Score | Key Driver |
|---|---|---|---|
| 1 | Context.Store | 2,926 | Extreme fan-in (36) x 33 functions = multiplicative blast |
| 2 | Inference.State | 1,843 | 56 functions x 17 dependents — huge API surface |
| 3 | Knowledge.Store | 1,760 | 37 functions x 18 dependents + 6 upstream deps |
| 4 | Tools.Registry | 1,292 | 32 fan-in — pure interface hub |
| 5 | Intelligence.SemanticIndex | 1,125 | High complexity (55) x coupling (50) |
| 6 | Core.ProjectContext | 1,071 | 25 functions x complexity (50) x 7 dependents |
| 7 | Inference.ContextBuilder | 1,040 | 20 functions x 11 dependents x coupling (28) |
| 8 | Inference.Transaction | 880 | Complexity (41) x 8 dependents x coupling (28) |
| 9 | Tools.RunTests | 873 | Complexity (54) x 7 dependents x coupling (26) |
| 10 | Prompt.Builder | 832 | Complexity (57) x 6 dependents x coupling (25) |

---

## Section 5: God Modules

| Module | Functions | Complexity | Score |
|---|---|---|---|
| AST.Extraction | 25 | 98 | 227 |
| Context.Store | 33 | 28 | 197 |
| Knowledge.Store | 41 | 30 | 155 |
| Prompt.Builder | 23 | 57 | 155 |
| Intelligence.SemanticIndex | 24 | 55 | 155 |

**AST.Extraction** (score 227): Highest complexity at 98. Only 2 fan-in — low risk to refactor. Complexity is by design: deep Sourceror AST traversal for 10 extraction functions.

Top complex functions:
| Function | Arity | Cognitive Complexity |
|---|---|---|
| extract_docs | 1 | 7 |
| extract_moduledoc | 1 | 5 |
| extract_optional_pairs | 1 | 5 |

Complexity is spread thin (max 7) — no single hotspot, just many moderately complex pattern-matching functions. Not a refactoring target.

**Context.Store** (score 197): 33 functions, 36 fan-in. Delegation hub — delegates to Query and Formatter sub-modules. No functions score >= 5 complexity. The high god score is from function count x centrality, not concentrated complexity. Already well-decomposed.

**Prompt.Builder** (score 155): 23 functions, complexity 57. Zero fan-in from low-risk callers. Testable pure logic.

Top complex functions:
| Function | Arity | Cognitive Complexity |
|---|---|---|
| find_relevant_ast | 2 | 8 |
| format_parameters | 1 | 5 |

Moderate concentration — `find_relevant_ast/2` at 8 is the hotspot.

**Intelligence.SemanticIndex** (score 155): 24 functions, complexity 55. Embedding pipeline with Nx/Bumblebee operations.

Top complex functions:
| Function | Arity | Cognitive Complexity |
|---|---|---|
| build_clusters | 2 | 7 |
| build_function_entries | 2 | 7 |
| build_module_entries | 2 | 5 |

Complexity spread across embedding construction — by design for ML pipeline.

---

## Section 6: Blast Radius (Top 3 Risk Modules)

### Context.Store (change_risk rank #1)

Depth 1 (direct dependents): 36 modules including Knowledge.Store, Intelligence.Preflight, Inference.ContextBuilder, Inference.Engine, Inference.Transaction, Prompt.Builder, Intelligence.SemanticIndex, Core.ProjectContext, Context.Indexer

Depth 2 (transitive): 31 additional modules including Inference.State, Daemon.Routers.Knowledge, Intelligence.PlanValidator, Storage.Arcade.Indexer, Runtime.Monitor, Inference.Orchestrator

Total blast radius: 67 modules affected
Function-level edges: 21 MFA call chains

**Cascading hub risk**: Knowledge.Store (Top 5 hub, rank #3) is a depth-1 dependent — modifying Context.Store could cascade through Knowledge.Store to its 18 dependents.

### Inference.State (change_risk rank #2)

Depth 1 (direct dependents): 17 modules — all Engine.* and ToolDispatch.* modules plus Orchestrator

Depth 2 (transitive): 2 additional modules (Inference.ContextBuilder, Inference.Pool)

Total blast radius: 19 modules affected
Function-level edges: 1 traced chain (stuck_in_loop?/2 -> Tracking.stuck_in_loop?/2)

Well-contained — blast radius is entirely within the inference subsystem.

### Knowledge.Store (change_risk rank #3)

Depth 1 (direct dependents): 18 modules including Daemon.Routers.Knowledge, Intelligence.ArchitectBrief, Intelligence.Preflight, Runtime.Inspector, Prompt.Builder

Depth 2 (transitive): 25 additional modules spanning inference, runtime, and daemon layers

Total blast radius: 43 modules affected
Function-level edges: 29 MFA call chains

**Cascading hub risk**: Context.Store (Top 5 hub, rank #1) is an upstream dependency — Knowledge.Store reads from Context.Store, so a Context.Store change cascades through Knowledge.Store to its 18 dependents.

---

## Section 7: Unprotected Hubs

No unprotected hubs detected. All hub modules (in-degree >= 3) have adequate spec/doc coverage.

---

## Section 8: Coupling Analysis (Top 10 Internal Pairs)

| Caller | Callee | Call Count | Distinct Functions |
|---|---|---|---|
| Knowledge.Topology | Graph | 46 | 14 |
| Inference.Engine | Inference.State | 39 | 15 |
| Knowledge.Insights | Enum | 39 | 12 |
| Client.Commands | Client.Output | 32 | 7 |
| Inference.State.Counters | Inference.State | 31 | 1 |
| Inference.State.Tracking | Inference.State | 27 | 1 |
| Daemon.Routers.Knowledge | Knowledge.Store | 24 | 21 |
| Knowledge.Store.Reader | Knowledge.Analyzer | 23 | 23 |
| Inference.Engine.Response | Inference.State | 22 | 14 |

**Notes:**
- State.Counters/Tracking -> State: by design — delegation pattern for the state struct
- Routers.Knowledge -> Knowledge.Store: by design — thin HTTP router dispatching to store
- Knowledge.Store.Reader -> Analyzer: by design — Reader delegates computation to Analyzer

All top coupling pairs are intentional architectural patterns (delegation, routing).

---

## Section 9: Dead Code

| Module | Function | Line |
|---|---|---|
| Storage.Arcade.Client | create_db/0 | 42 |
| Storage.Arcade.Client | list_projects/0 | 273 |
| Storage.Arcade.Consolidator | consolidate/0 | 36 |
| Storage.Arcade.Consolidator | status/0 | 41 |

4 functions out of 1,482 total (0.3%).

All 4 are ArcadeDB public API functions intended for manual/REPL use — called via `iex` or external triggers, not from within the codebase. **False positives** — these are intentionally exposed entry points.

---

## Section 10: Struct Lifecycle

| Struct | Defining Module | User Count | Logic Leaks | Leak Count |
|---|---|---|---|---|
| Transaction | Inference.Transaction | 1 | Inference.State | 1 |
| State | Inference.State | 0 | — | 0 |
| Approval | Inference.Approval | 0 | — | 0 |
| PathSandbox | Core.PathSandbox | 0 | — | 0 |
| ProjectContext | Core.ProjectContext | 0 | — | 0 |
| Pool | Inference.Pool | 0 | — | 0 |

Only 1 struct coupling: Inference.State pattern-matches on Transaction struct fields. This is idiomatic Elixir — State manages Transaction as part of OODA orchestration. Both modules are in the same subsystem.

5 structs with 0 external users — well-encapsulated, accessed only through their module's API.

---

## Section 11: Semantic Duplicates

0 clusters found. EmbeddingServing is available and returned no duplicates above the default 85% threshold.

---

## Section 12: Architecture Health

| Check | Status |
|---|---|
| Circular dependencies | 3 cycles found |
| Behaviour integrity | Consistent — 0 fractures |
| Orphan specs | 0 |
| Dead code | 4 functions (0 genuinely unused) |

**Cycles (P0):**
1. **Client -> Client.Commands -> Client.Daemon -> Client.REPL** — CLI module cycle. Client.Commands dispatches to sub-modules which call back to Client.
2. **Context.Store -> Context.Store.Formatter -> Context.Store.Query** — internal delegation cycle within the Store decomposition.
3. **Inference.State -> Inference.State.Counters -> Inference.State.Tracking** — same pattern: parent struct module delegates to sub-modules which reference the parent type.

Cycles 2 and 3 are structural artifacts of the delegation pattern (parent module + sub-modules sharing a type). These are common in Elixir when a large module is decomposed. Cycle 1 (Client) is a real architectural issue — the CLI modules should have clearer directional flow.

---

## Section 13: Runtime Health

| Metric | Value |
|---|---|
| Processes | 550 |
| Memory | 143.4 MB |
| Schedulers | 24 |
| Run Queue | 3 |
| Uptime | 3,926s (~1h) |
| ETS Tables | 71 |
| ETS Memory | 10.33 MB |

**God Tables:**
| Table | Size | Memory |
|---|---|---|
| EXLA.Defn.LockedCache | 3,716 entries | 3.89 MB |
| :giulia_runtime_snapshots | 600 entries | 1.56 MB |
| Giulia.Context.Store | 266 entries | 1.56 MB |
| :giulia_knowledge_graphs | 4 entries | 1.15 MB |

No warnings. Run queue at 3 is normal during active scan.

**Hot Spots:**

| Module | Reductions % | Memory |
|---|---|---|
| EXLA.Defn.Lock | 61.4% | 6.8 KB |
| Runtime.Collector | 29.4% | 2,486.8 KB |
| Giulia.Supervisor | 5.0% | 8.3 KB |
| Persistence.Writer | 2.4% | 3,073.5 KB |

EXLA.Defn.Lock dominance is expected — it manages the NIF lock for XLA tensor operations during embedding. Runtime.Collector at 29.4% is expected — it runs 30-second snapshot cycles continuously. Persistence.Writer memory (3 MB) reflects buffered write-behind operations. All expected patterns.

---

## Section 14: Recommended Actions (Priority Order)

**P0 — Blocking:**

1. **Break Client cycle**: Client -> Commands -> Daemon -> REPL forms a circular dependency. Refactor Client.Commands to not call back into Client directly — extract shared state/config into a separate module.

**P1 — High Risk:**

(None — all hubs are adequately protected with specs/docs. Zero unprotected hubs.)

**P2 — Improvement Opportunities:**

2. **Add tests for Prompt.Builder**: Complexity 57, 6 dependents, pure functions — highest-leverage untested module. Expected impact: reduce heatmap score from ~38 to ~13.
3. **Add tests for Intelligence.SemanticIndex**: Only red-zone module (score 65). Even basic embedding availability tests would drop it to yellow (~40).
4. **Add tests for Knowledge.Metrics**: Pure computation module with scoring formulas — trivially testable with fixture data.

---

Generated by Giulia v0.1.0.142 — D:/Development/GitHub/Giulia — 70 endpoints, 2026-03-24
