# Giulia Project Analysis Report — Build 98

**Date**: 2026-02-24 09:50 UTC
**Version**: v0.1.0.98 (Discovery Engine)
**Node**: `giulia@0.0.0.0`

---

## 1. Executive Summary

| Metric | Value |
|--------|-------|
| Source files | 89 |
| Modules | 89 |
| Functions | 1,098 |
| Types | 47 |
| Specs | 223 (20.3% coverage) |
| Structs | 6 |
| Callbacks | 7 |
| Graph vertices | 1,187 |
| Graph edges | 1,467 |
| Connected components | 288 |
| API skills | 55 (across 9 categories) |
| Circular dependencies | 0 |
| Orphan specs | 0 |
| Behaviour fractures | 0 (consistent) |
| Dead code | 5 functions |
| BEAM processes | 534 |
| BEAM memory | 91.3 MB |
| Runtime warnings | 0 |
| Runtime alerts | 0 |

**Verdict**: Healthy codebase with zero cycles, zero fractures, zero orphan specs. 10 red-zone modules need attention. Test coverage is the single biggest gap — zero modules have tests outside the existing 660-test suite for `Context.Store` and `Inference.State`.

---

## 2. Heatmap Zones

### Red Zone (score >= 60) — 10 modules

| Module | Score | Complexity | Centrality | Max Coupling | Tests? |
|--------|-------|-----------|-----------|-------------|--------|
| Context.Store | 78 | 54 | 23 | 42 | No |
| AST.Processor | 75 | 164 | 5 | 50 | No |
| Knowledge.Store | 74 | 68 | 14 | 32 | No |
| Client | 67 | 182 | 0 | 108 | No |
| Knowledge.Analyzer | 67 | 146 | 2 | 170 | No |
| Inference.Engine | 60 | 111 | 1 | 91 | No |
| Intelligence.SemanticIndex | 60 | 43 | 7 | 41 | No |
| Inference.ToolDispatch | 60 | 93 | 2 | 75 | No |
| Core.PathMapper | 60 | 22 | 11 | 27 | No |
| Tools.Registry | 60 | 19 | 30 | 8 | No |

### Yellow Zone (score 30-59) — 54 modules

### Green Zone (score < 30) — 25 modules

Including all 9 domain routers (Approval, Discovery, Index, Intelligence, Knowledge, Monitor, Runtime, Search, Transaction) — the Build 94 decoupling was highly effective.

---

## 3. Top 5 Hubs (Highest Fan-In)

| Module | In-Degree | Risk Profile |
|--------|-----------|-------------|
| Tools.Registry | 30 | Pure hub — everything depends on it, depends on nothing. Stable interface. |
| Context.Store | 23 | Data store — 33 public functions, 0 private. Wide API surface, red zone. |
| Inference.Engine | 18 (1 in, 17 out) | Fan-out monster — depends on 17 modules. OODA loop core. |
| Knowledge.Store | 17 (14 in, 3 out) | GenServer wrapper — delegates to Analyzer. Recently refactored (builds 81-82). |
| Core.PathSandbox | 13 | Security boundary — pure fan-in, zero fan-out. Stable. |

---

## 4. Change Risk (Top 10)

| Rank | Module | Score | Key Driver |
|------|--------|-------|-----------|
| 1 | Context.Store | 3,225 | Centrality 23 + 33 public fns + 100% API ratio |
| 2 | Knowledge.Store | 2,200 | Centrality 14 + 32 public fns |
| 3 | AST.Processor | 1,757 | Complexity 164 + coupling 50 |
| 4 | Knowledge.Analyzer | 1,438 | Complexity 146 + coupling 170 (Enum-heavy) |
| 5 | Tools.Registry | 1,216 | Centrality 30 (highest in project) |
| 6 | Core.ProjectContext | 1,161 | Complexity 75 + 25 public fns |
| 7 | Intelligence.SemanticIndex | 909 | Centrality 7 + coupling 41 |
| 8 | Inference.State | 798 | 56 public functions (pure state module) |
| 9 | Inference.ToolDispatch | 780 | Complexity 93 + coupling 75 |
| 10 | Core.PathMapper | 780 | Centrality 11 (utility hub) |

---

## 5. God Modules (Weighted: Functions + Complexity + Centrality)

| Module | Functions | Complexity | Score |
|--------|-----------|-----------|-------|
| Client | 49 | 182 | 413 |
| AST.Processor | 47 | 164 | 390 |
| Knowledge.Analyzer | 50 | 146 | 348 |
| Inference.Engine | 20 | 111 | 245 |
| Inference.ContextBuilder | 31 | 100 | 237 |
| Inference.ToolDispatch | 28 | 93 | 220 |

**Client** is the #1 god module (182 complexity, 49 functions) but has zero fan-in — it's a leaf. This means it's high-complexity but low-risk to refactor since nothing depends on it.

**AST.Processor** remains the #2 target — planned split into Reader/Writer/Metrics (Build 85 plan) would drop its complexity from 164 to ~60.

---

## 6. Unprotected Hubs (Red Severity)

13 hub modules lack adequate spec coverage:

| Module | In-Degree | Spec Coverage | Severity |
|--------|-----------|--------------|----------|
| Daemon.Helpers | 11 | 0% (0/6) | RED |
| SkillRouter | 9 | 0% (0/1) | RED |
| SemanticIndex | 7 | 11% (1/9) | RED |
| ProjectContext | 7 | 0% (0/25) | RED |
| Transaction | 6 | 0% (0/14) | RED |
| StructuredOutput | 6 | 0% (0/4) | RED |
| Events | 4 | 0% (0/7) | RED |
| RunTests | 4 | 17% (1/6) | RED |
| ContextManager | 3 | 0% (0/9) | RED |
| Approval | 3 | 0% (0/11) | RED |

**Key insight**: 223 specs exist project-wide (20.3% coverage), but they're concentrated in a few modules. Hub modules — the ones where specs matter most — have near-zero coverage.

---

## 7. Coupling Analysis (Top 10 Pairs)

| Caller | Callee | Call Count | Distinct Functions |
|--------|--------|-----------|-------------------|
| Knowledge.Analyzer | Enum | 170 | 18 |
| Client | IO | 108 | 4 |
| Inference.Engine | State | 91 | 29 |
| Inference.ToolDispatch | State | 75 | 21 |
| Knowledge.Analyzer | Graph | 67 | 16 |
| Client | String | 66 | 16 |
| Inference.Engine | Logger | 65 | 4 |
| AST.Processor | Enum | 50 | 15 |
| Knowledge.Analyzer | MapSet | 47 | 8 |
| Context.Store | Enum | 42 | 12 |

The Engine↔State coupling (91+75 = 166 calls) is by design — State is the pure-functional state manager extracted in Build 83. This coupling is healthy (thin GenServer + pure functions).

---

## 8. Dead Code

| Module | Function | Line |
|--------|----------|------|
| Giulia | version/0 | 50 |
| Application | start_daemon_services/0 | 133 |
| Context.Builder | build_tools_list/0 | 53 |
| SkillRouter | __skills__/0 | 54 |
| Version | full_version/0 | 16 |

5 functions out of 1,098 (0.45%). `SkillRouter.__skills__/0` is a false positive — it's the base definition overridden by each router's `@before_compile`. The other 4 are genuinely unused and safe to remove.

---

## 9. Runtime Health

| Metric | Value |
|--------|-------|
| Processes | 534 |
| Memory | 91.3 MB |
| Schedulers | 24 |
| Run queue | 0 |
| Uptime | 246s |
| ETS tables | 68 |
| Largest ETS | `:code_server` (946 entries, 0.73 MB) |
| Warnings | 0 |
| Alerts | 0 |

**Hot Spots** (by reductions):

| Module | Reductions % | Memory |
|--------|-------------|--------|
| Giulia.Supervisor | 71.3% | 6.2 KB |
| Runtime.Collector | 13.2% | 416.5 KB |
| EmbeddingServing | 8.9% | 1,089 KB |
| :code_server | 4.4% | 2,849 KB |
| :proc_lib | 2.2% | 1,516 KB |

Supervisor reductions are from startup (application tree init). Collector and EmbeddingServing are expected steady-state consumers. No anomalies.

---

## 10. Architecture Health

| Check | Status |
|-------|--------|
| Circular dependencies | **0** — Clean DAG |
| Behaviour integrity | **Consistent** — 0 fractures |
| Orphan specs | **0** — All specs match functions |
| Dead code | **5** — 4 genuinely unused, 1 false positive |
| Runtime alerts | **0** — No memory leaks, no queue pressure |

---

## 11. Build 94-98 Impact Assessment

The last 4 builds delivered significant architectural improvements:

| Build | Change | Measurable Impact |
|-------|--------|-------------------|
| 94 | Endpoint split → 7 sub-routers | Endpoint: 1,331→266 lines (80% reduction), now green zone (score 32) |
| 95 | Logic Monitor (telemetry) | 3 new routes, zero runtime overhead when unused |
| 96 | Global Logic Tap | Every HTTP request visible in dashboard |
| 97 | Metric caching | heatmap/change_risk: 570-1166ms → <10ms warm |
| 98 | Discovery Engine | SKILL.md: 349→75 lines (90% context reduction), 55 self-describing routes |

---

## 12. Recommended Next Actions (Priority Order)

### P0: Spec Coverage for Hub Modules
10 red-severity unprotected hubs. Adding `@spec` to the top 5 hubs (Registry, Context.Store, Knowledge.Store, PathSandbox, PathMapper) would protect 94 of the most-depended-on functions.

### P1: AST.Processor Split (Build 85 plan)
Score 75, complexity 164, 47 functions doing 4 jobs. Split into Reader/Writer/Metrics as planned. Expected: complexity 164→~60, heatmap 75→~10.

### P2: Client Refactor
Score 67, complexity 182 (highest in project), 49 functions, 44 private. Zero dependents — safe refactoring target. Split rendering (IO-heavy) from HTTP logic.

### P3: Dead Code Cleanup
Remove 4 genuinely unused functions. Trivial but keeps the codebase honest.

### P4: Context.Store API Surface Reduction
33 public functions, 0 private. API ratio 1.0 — everything is public. Audit which functions are truly needed externally vs. could be `defp`.

---

*Generated by Giulia's own Knowledge Graph, Heatmap, and Runtime Introspection APIs (Build 98)*
*55 self-describing endpoints across 9 categories — zero manual grep required*
