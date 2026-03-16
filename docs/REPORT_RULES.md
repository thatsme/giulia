# Giulia Analysis Report — Generation Rules

This document defines the standard procedure for generating a project analysis report
using Giulia's API. It is the canonical reference for both human operators and AI agents.

## Prerequisites

1. Giulia daemon running (`GET /health` returns `status: ok`)
2. Project scanned (`POST /api/index/scan` with project path)
3. Wait for scan completion — poll `GET /api/index/status?path=...` until `state: idle`
4. Knowledge graph built — verify `GET /api/knowledge/stats?path=...` returns `vertices > 0`

If the graph has 0 vertices after scan, the graph builder crashed. Check daemon logs.

---

## Key Scoring Formulas

These formulas drive the two most-referenced sections (Heatmap and Change Risk).
Understand them before interpreting any results.

### Heatmap Score (0-100)

```
norm_centrality = min(in_degree / 15 * 100, 100)    — weight 0.30
norm_complexity = min(complexity / 200 * 100, 100)   — weight 0.25
norm_test       = if has_test, 0, else 100            — weight 0.25
norm_coupling   = min(max_coupling / 50 * 100, 100)  — weight 0.20
score           = weighted sum, truncated to integer
```

**Critical interaction: test weight = 0.25 means every module without a matching
`_test.exs` file gets a 25-point floor penalty regardless of all other factors.**
A module with zero centrality, zero complexity, and zero coupling still scores 25
if it has no test file. Conversely, a well-tested module gets a 25-point floor
reduction. Before interpreting heatmap results — especially red-zone counts —
verify test detection is working correctly (`has_test` values are plausible for
the project). A broken test detector inflates ALL scores by 25 points.

### Change Risk Score

```
change_risk = centrality * function_count * (1 + complexity_norm + coupling_norm)
```

Where:
- `centrality` = in-degree (number of modules that depend on this one)
- `function_count` = total public + private functions
- `complexity_norm` = module-level AST complexity / 100 (counts control flow nodes across the whole file)
- `coupling_norm` = max coupling to any single module / 50

**Module-level vs per-function complexity**: Heatmap and change_risk use module-level complexity
(total control flow nodes in the file). Per-function cognitive complexity (Sonar-style, nesting-aware)
is available via `GET /api/index/complexity` and is included in `/api/index/functions` responses.
Use per-function complexity in God Modules drill-downs (Section 5) to pinpoint WHERE complexity
concentrates within a module.

This is a multiplicative formula — a module with high centrality AND high function
count AND high complexity will have an exponentially higher score than one with only
one factor elevated. This is intentional: the risk of modifying a module compounds
across dimensions.

---

## Data Collection Phase

Call endpoints in this order. All require `?path=<project_path>` query param.

### Stage 1: Index (fast, ETS-backed)

| Endpoint | Key Fields | Report Section |
|----------|-----------|----------------|
| `GET /api/index/summary` | modules, functions, types, specs, structs, callbacks | Executive Summary |
| `GET /api/index/status` | files_scanned, state, cache_status | Executive Summary |
| `GET /api/index/complexity` | per-function cognitive complexity, sorted desc | God Modules drill-down |

### Stage 2: Knowledge Graph Topology (graph-backed)

| Endpoint | Key Fields | Report Section |
|----------|-----------|----------------|
| `GET /api/knowledge/stats` | vertices, edges, components, hubs, type_counts | Executive Summary |
| `GET /api/knowledge/cycles` | cycles list | Architecture Health |
| `GET /api/knowledge/integrity` | status, fractures | Architecture Health |
| `GET /api/knowledge/fan_in_out` | per-module in/out degree | Top Hubs |
| `GET /api/knowledge/dead_code` | unused functions | Dead Code |
| `GET /api/knowledge/orphan_specs` | specs without matching function | Architecture Health |

### Stage 3: Risk Analysis (graph + AST, heavier)

| Endpoint | Key Fields | Report Section |
|----------|-----------|----------------|
| `GET /api/knowledge/heatmap` | per-module score, zone, breakdown (complexity, centrality, coupling, has_test) | Heatmap Zones |
| `GET /api/knowledge/change_risk` | ranked modules with composite scores | Change Risk |
| `GET /api/knowledge/god_modules` | functions, complexity, score | God Modules |
| `GET /api/knowledge/coupling` | caller/callee pairs with call counts | Coupling Analysis |
| `GET /api/knowledge/unprotected_hubs` | hub modules with low spec/doc coverage | Unprotected Hubs |

### Stage 4: Deep Analysis (struct lifecycle, duplicates, preflight)

| Endpoint | Key Fields | Report Section |
|----------|-----------|----------------|
| `GET /api/knowledge/struct_lifecycle` | struct data flow, logic leaks, users | Struct Lifecycle |
| `GET /api/knowledge/duplicates` | semantic duplicate function clusters | Semantic Duplicates |
| `POST /api/briefing/preflight` | per-module 6-contract checklist | Preflight (appendix) |

### Stage 5: Runtime (if daemon is analyzing itself or connected node)

| Endpoint | Key Fields | Report Section |
|----------|-----------|----------------|
| `GET /api/runtime/pulse` | processes, memory, schedulers, run_queue, uptime | Runtime Health |
| `GET /api/runtime/top_processes` | top N by reductions/memory | Hot Spots |
| `GET /api/runtime/hot_spots` | module-level CPU/memory fusion | Hot Spots |

---

## Report Structure

The report MUST follow this section order. Every section is mandatory unless
the data source explicitly failed (in which case, note the failure).

### Section 1: Executive Summary

A single table with all key metrics. This is the first thing the reader sees.

**Required fields:**
- Source files, Modules, Functions, Types, Specs (with coverage %), Structs, Callbacks
- Graph vertices, edges, connected components
- Circular dependencies count
- Behaviour fractures count
- Orphan specs count
- Dead code count

**Rules:**
- Spec coverage = specs / **public** functions only. The summary endpoint's "Functions" count
  includes both `def` and `defp`. Specs only apply to public functions (`def`), so dividing
  specs by total functions understates coverage. To get the correct denominator:
  1. Preferred: use `change_risk` endpoint which reports `public_functions` and `private_functions`
     per module — sum `public_functions` across all modules.
  2. Fallback: if change_risk is paginated, grep source files:
     `grep -r "^\s*def " lib/ --include="*.ex"` excluding defp/defmodule/defmacro/defstruct/etc.
  3. Report BOTH numbers: "469 specs / 912 public functions (51.4%)" — never divide by total.
- End with a 1-2 sentence **Verdict** — overall health assessment with the single biggest gap called out

### Section 2: Heatmap Zones

Three sub-tables: Red (>= 60), Yellow (30-59), Green (< 30).

**Red Zone table columns:** Module | Score | Complexity | Centrality | Max Coupling | Tests?

**Rules:**
- Red zone: list ALL modules individually with full breakdown
- Yellow zone: list ALL modules individually (abbreviated — score and zone only is acceptable for large projects)
- Green zone: count only, optionally list notable modules
- `has_test` comes from real file cross-referencing (`suggest_test_file` maps `lib/foo.ex` to `test/foo_test.exs` and checks `File.exists?`). It is NOT inferred. If has_test is false, there is genuinely no matching `_test.exs` file by naming convention. Note: non-standard test locations (e.g., `test/livebook_teams/` for a `Livebook.Hubs` module) will show as false — the detection uses path convention only.
- See "Key Scoring Formulas" above for the test weight interaction — verify `has_test` values are plausible before interpreting red-zone counts

### Section 3: Top 5 Hubs

Sorted by in-degree (fan-in). Shows which modules are most dangerous to modify.

**Table columns:** Module | In-Degree | Out-Degree | Risk Profile

**Rules:**
- Use `fan_in_out` endpoint data, cross-referenced with `centrality` for the top 5
- Risk Profile is a 1-sentence human-readable assessment:
  - Pure hub (high in, low out): "Stable interface — everything depends on it"
  - Fan-out monster (low in, high out): "Orchestrator — depends on many, few depend on it"
  - Bidirectional hub (high in AND out): "Critical junction — high blast radius in both directions"

### Section 4: Change Risk (Top 10)

**Table columns:** Rank | Module | Score | Key Driver

**Rules:**
- Use `change_risk` endpoint, take top 10
- Key Driver: identify the dominant factor (centrality, complexity, coupling, function count)
- See "Key Scoring Formulas" above for the full change_risk formula and why it's multiplicative

### Section 5: God Modules

**Table columns:** Module | Functions | Complexity | Score

**Rules:**
- Use `god_modules` endpoint
- Add 1-sentence commentary per module: is it a refactoring target? Is the complexity by design?
- Call out god modules with zero fan-in — they're high complexity but LOW risk to refactor (nothing depends on them)
- **Per-function complexity drill-down**: For each god module, query
  `GET /api/index/complexity?path=<path>&module=<name>&min=5&limit=3` to show the top 3
  most cognitively complex functions. Present as a sub-table under each god module entry:

  | Function | Arity | Cognitive Complexity |
  |---|---|---|
  | handle_call | 3 | 14 |
  | do_scan | 1 | 9 |
  | process_file | 2 | 7 |

  This pinpoints WHERE the complexity lives — a 200-complexity module with one 45-score
  function is a different beast than one with 20 functions averaging 10. Skip the sub-table
  if no function scores >= 5 (the module's complexity is spread thin, not concentrated).

### Section 6: Blast Radius (Top 3 Risk Modules) — MANDATORY

This is the most valuable section. For the top 3 modules from change_risk:

**Per module, call:**
```
GET /api/knowledge/impact?module=<name>&path=<path>&depth=2
```

**Format:**
```
### <Module Name> (change_risk rank #N)

Depth 1 (direct dependents): <list of modules>
Depth 2 (transitive): <list of modules not in depth 1>

Total blast radius: N modules affected
Function-level edges: <count> MFA→MFA call edges
```

**Rules:**
- Always use depth=2
- Separate depth-1 and depth-2 modules explicitly — this is what makes risk concrete
- Include the function_edges count if available
- **Cascading hub risk**: if a depth-2 module appears in the report's Top 5 Hubs list
  (Section 3), flag it as "cascading hub risk — modifying <root> could cascade through
  <hub> to its N dependents." Use the Top 5 Hubs list as the threshold, not a fixed
  in-degree number — this scales naturally with project size.

### Section 7: Unprotected Hubs

**Table columns:** Module | In-Degree | Spec Coverage | Severity (red/yellow)

**Rules:**
- Use `unprotected_hubs` endpoint
- Only show red and yellow severity (green hubs are adequately protected)
- Add a key insight line: how many specs exist project-wide and where they're concentrated

### Section 8: Coupling Analysis (Top 10 Pairs)

**Table columns:** Caller | Callee | Call Count | Distinct Functions

**Rules:**
- Use `coupling` endpoint, take top 10
- Ignore stdlib coupling (Enum, Map, String, Logger, etc.) — only report project-internal coupling
- If coupling is "by design" (e.g., thin GenServer + pure state module), note it

### Section 9: Dead Code

**Table columns:** Module | Function | Line

**Rules:**
- Use `dead_code` endpoint
- Flag known false positives:
  - `__skills__/0` in SkillRouter base module (overridden by `@before_compile`)
  - Callback implementations that appear unused at the source level
  - Functions called only via `apply/3` or dynamic dispatch
- State the ratio: N functions out of M total (X%)

### Section 10: Struct Lifecycle

**Table columns:** Struct | Defining Module | User Count | Logic Leaks | Leak Count

**Rules:**
- Use `struct_lifecycle` endpoint
- **Logic leaks**: modules that reference a struct but are not the defining module — potential
  encapsulation violations where struct internals are accessed outside their owning context
- Sort by leak_count descending — highest leak count = worst encapsulation
- User Count is the number in the table; list the actual user module names in commentary
  below the table only for structs with leaks > 0 (keeps the table scannable)
- If a struct has 0 users outside its defining module, it's well-encapsulated — no action needed
- If a struct has 0 users total (including its own module), flag as "potentially unused struct"
- Commentary: not all logic leaks are bugs — shared data structures (e.g., `%User{}` across
  contexts) will naturally appear. Flag the pattern, let the reader judge intent.

### Section 11: Semantic Duplicates

**Rules:**
- Use `duplicates` endpoint
- Report: "N clusters found at >= X% similarity threshold"
- List top 3 clusters with their similarity score and member function names
- **False positive caveat**: large clusters of accessor functions (`get_x/1`, `set_x/2`),
  delegate functions (`defdelegate`), or simple CRUD wrappers are expected to cluster —
  they share structural patterns, not duplicated logic. Flag these as "structural similarity,
  not duplication" when the cluster members are all accessors/delegates.
- If EmbeddingServing is unavailable (503), note: "Semantic duplicates unavailable — EmbeddingServing not loaded"

### Section 12: Architecture Health

A pass/fail checklist table:

| Check | Status |
|-------|--------|
| Circular dependencies | 0 — Clean DAG / N cycles found |
| Behaviour integrity | Consistent / N fractures |
| Orphan specs | 0 / N orphans found |
| Dead code | N functions (M genuinely unused) |

**Rules:**
- Cycles > 0 is a P0 issue — list the cycle chains
- Fractures > 0 is a P1 issue — list which behaviours/implementers are broken
- Orphan specs indicate refactoring debris — list them for cleanup

### Section 13: Runtime Health (if available)

**Table 1:** Processes | Memory | Schedulers | Run Queue | Uptime | ETS Tables

**Table 2 (Hot Spots):** Module | Reductions % | Memory

**Rules:**
- Only include if runtime data is available (self-introspection or connected node)
- Run queue > 0 sustained = scheduler pressure, flag as warning
- Memory > 500MB = investigate, flag largest ETS tables
- Hot spots: top 5 by reductions, note if expected (e.g., supervisor at startup) or anomalous

### Section 14: Recommended Actions (Priority Order)

Synthesize findings into concrete, prioritized recommendations.

**Priority levels:**
- **P0**: Blocking issues — cycles, behaviour fractures, crashes
- **P1**: High-risk gaps — unprotected hubs, god modules with high fan-in
- **P2**: Improvement opportunities — god module splits, coupling reduction, dead code
- **P3**: Polish — spec coverage for non-hub modules, doc coverage

**Rules:**
- Each recommendation must reference specific data from the report (module name, score, metric)
- Include expected impact: "splitting X would reduce complexity from N to ~M"
- **P0 and P1 items are never capped** — list every blocking/high-risk issue
- **P2 and P3 items are limited to 3 combined** — focus on highest leverage
- This means a clean project might have 3 recommendations total (all P2/P3), while a
  project with systemic issues could have 10+ (7 P0/P1 + 3 P2/P3)

---

## Formatting Rules

1. **File naming**: `<ProjectName>_REPORT_<YYYYMMDDHH>.md`
2. **Module names**: Use short form (drop common prefix). `Giulia.Context.Store` → `Context.Store`
3. **Numbers**: Use commas for thousands (1,098 not 1098)
4. **Percentages**: One decimal place (20.3% not 20.312%)
5. **Scores**: Integer only (truncate, don't round)
6. **Tables**: Always use markdown tables with simple separators (`|---|`). Two sub-rules:
   - **Never use backticks inside table cells.** Many Markdown editors (Discourse, CommonMark-strict
     parsers) break when inline code formatting appears inside `| |` pipes. Write module names
     as plain text in tables: `SymphonyElixir.Config` in prose, but just `SymphonyElixir.Config`
     (no backticks) inside a table cell.
   - **Use uniform short separators.** Write `|---|---|---|` not `|--------|---------|----------|`.
     Variable-width separators add no value and some parsers handle them inconsistently.
7. **Commentary**: Keep per-row commentary to 1 sentence max. Longer analysis goes after the table.
8. **Footer**: Always include: `Generated by Giulia v<version> — <project_path> — <endpoint_count> endpoints, <date>`

---

## Error Handling

If any endpoint returns non-200:
- **500 with detail**: Report the error message in the section, proceed to next section
- **500 without detail**: Note "endpoint crashed — no error detail available" (this should not happen after Build 126)
- **404**: Module/vertex not found — note it and skip
- **503**: Service unavailable (e.g., EmbeddingServing not loaded) — note it, section marked "unavailable"
- **Timeout**: Note timeout, section marked "timed out"

NEVER skip a section silently. Every section must appear, even if just to say "data unavailable".

---

## Anti-Patterns (Do NOT Do These)

1. **Don't grep for dependencies** — use the knowledge graph. Grep misses indirect deps.
2. **Don't infer test existence** — `has_test` is real file detection, not inference. If it says false, the file doesn't exist (by naming convention).
3. **Don't report stdlib coupling as a problem** — Enum/Map/String coupling is normal Elixir.
4. **Don't report god modules without fan-in context** — a 200-complexity leaf module is a refactoring opportunity, not a risk.
5. **Don't generate the report before the graph is built** — graph-dependent sections will all be empty/wrong.
6. **Don't skip blast radius** — Section 6 is mandatory for every report. It's what makes risk concrete.
7. **Don't use a fixed in-degree threshold for cascading hub risk** — use the Top 5 Hubs list from the same report. What counts as a "hub" scales with project size.
8. **Don't interpret heatmap red zones without checking test detection** — a broken test detector inflates all scores by 25 points (see scoring formula interaction).
