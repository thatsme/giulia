# Giulia Analysis Report — Generation Rules

This document defines the standard procedure for generating a project analysis report
using Giulia's API. It is the canonical reference for both human operators and AI agents.

## Prerequisites

1. Giulia daemon running (`GET /health` returns `status: ok`)
2. Project scanned (`POST /api/index/scan` with project path). A 422 response means the path is missing, not a directory, or lacks a project marker (mix.exs / GIULIA.md / package.json / Cargo.toml / go.mod) — fix the input before retrying.
3. Wait for scan completion — poll `GET /api/index/status?path=...` until `state` is `idle` OR `empty`. Both are terminal; `empty` means the scan completed with zero indexed files (wrong subdirectory, over-aggressive ignore rules, or a deps-only project) and downstream steps will return empty/zero results. Stop and investigate rather than polling further.
4. Knowledge graph built — verify `GET /api/knowledge/stats?path=...` returns `vertices > 0`

If the graph has 0 vertices after scan, either the indexer produced zero files (`state: empty` — see step 3) or the graph builder crashed. Check daemon logs.

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
|---|---|---|
| `GET /api/index/summary` | modules, functions, types, specs, structs, callbacks | Executive Summary |
| `GET /api/index/status` | files_scanned, state, cache_status | Executive Summary |
| `GET /api/index/complexity` | per-function cognitive complexity, sorted desc | God Modules drill-down |
| `GET /api/knowledge/api_surface` | public/private function ratio per module | Executive Summary, API Surface |

### Stage 2: Knowledge Graph Topology (graph-backed)

| Endpoint | Key Fields | Report Section |
|---|---|---|
| `GET /api/knowledge/stats` | vertices, edges, components, hubs, type_counts | Executive Summary |
| `GET /api/knowledge/cycles` | cycles list | Architecture Health |
| `GET /api/knowledge/integrity` | status, fractures | Architecture Health |
| `GET /api/knowledge/fan_in_out` | per-module in/out degree | Top Hubs |
| `GET /api/knowledge/dead_code` | unused functions | Dead Code |
| `GET /api/knowledge/orphan_specs` | specs without matching function | Architecture Health |

### Stage 3: Risk Analysis (graph + AST, heavier)

| Endpoint | Key Fields | Report Section |
|---|---|---|
| `GET /api/knowledge/heatmap` | per-module score, zone, breakdown (complexity, centrality, coupling, has_test) | Heatmap Zones |
| `GET /api/knowledge/change_risk` | ranked modules with composite scores | Change Risk |
| `GET /api/knowledge/god_modules` | functions, complexity, score | God Modules |
| `GET /api/knowledge/coupling` | caller/callee pairs with call counts | Coupling Analysis |
| `GET /api/knowledge/unprotected_hubs` | hub modules with low spec/doc coverage | Unprotected Hubs |

### Stage 4: Deep Analysis (audit, lifecycle, duplicates, preflight)

**Optimization (Build 140+):** Use `GET /api/knowledge/audit` as a single call to retrieve
unprotected_hubs + struct_lifecycle + duplicates + behaviour integrity combined. This replaces
4 separate calls. Fall back to individual endpoints only if audit returns an error.

| Endpoint | Key Fields | Report Section |
|---|---|---|
| `GET /api/knowledge/audit` | combined: unprotected_hubs, struct_lifecycle, duplicates, integrity | Sections 7, 10, 11, 12 |
| `GET /api/knowledge/struct_lifecycle` | struct data flow, logic leaks, users | Struct Lifecycle (fallback) |
| `GET /api/knowledge/duplicates` | semantic duplicate function clusters | Semantic Duplicates (fallback) |
| `POST /api/briefing/preflight` | per-module 6-contract checklist | Preflight (appendix) |

### Stage 5: Blast Radius Enrichment (Build 140+)

For the top 3 change_risk modules, optionally enrich with function-level detail:

| Endpoint | Key Fields | Report Section |
|---|---|---|
| `GET /api/knowledge/logic_flow` | step-by-step function call path between two MFAs | Blast Radius (Section 6) |
| `POST /api/knowledge/pre_impact_check` | callers, risk score, phased migration plan | Change Risk enrichment |

`logic_flow` takes `?from=<MFA>&to=<MFA>&path=<path>` — use it to trace HOW a change in
module A reaches module B at the function level. This makes blast radius concrete: not just
"A affects B" but "A.foo/2 → C.bar/1 → B.handle/3".

`pre_impact_check` takes `{"module": "<name>", "action": "rename|remove", "path": "<path>"}` —
use it for the top 3 risk modules to show what a rename/remove would actually break, with
a phased migration plan. Include this as a sub-section under each blast radius entry when
the action is relevant (e.g., god module split recommendations).

### Stage 6: Runtime (if daemon is analyzing itself or connected node)

| Endpoint | Key Fields | Report Section |
|---|---|---|
| `GET /api/runtime/pulse` | processes, memory, schedulers, run_queue, uptime | Runtime Health |
| `GET /api/runtime/top_processes` | top N by reductions/memory | Hot Spots |
| `GET /api/runtime/hot_spots` | module-level CPU/memory fusion | Hot Spots |
| `GET /api/runtime/profile/latest` | hot modules, bottleneck analysis, peak metrics | Performance Profile |
| `GET /api/runtime/observations` | fused observation sessions (static + runtime) | Fused Observations |
| `GET /api/runtime/observation/:session_id` | full fused profile with correlation data | Fused Observations |

### Stage 7: External Tool Findings (Build 156+, conditional)

Run only when external-tool enrichments have been ingested for the project.
A simple existence check before this stage: if `dead_code.dead[*].enrichments`
is uniformly `%{}` across the response, no tool has been ingested for this
project — skip Stage 7 entirely.

The findings are not fetched via a dedicated bulk endpoint. They flow
through two paths Stage 4 / Stage 5 already collect:

- **Inline on `dead_code` entries** — every `dead[i].enrichments` is a
  `%{tool => [findings]}` map. Already in the response from Stage 4.
- **Inline on `pre_impact_check.affected_callers`** — every caller carries
  `:enrichments` for any pre-impact-check run during Stage 5 (Blast
  Radius Enrichment).

The dedicated endpoint is `GET /api/intelligence/enrichments?path=P&mfa=...`
(or `&module=...`) — uncapped per-vertex drill-down. **Use this when**:

- A `pre_impact_check` response contains an `:enrichments_summary` (the
  per-response cap fired and per-caller `:enrichments` were cleared in
  favor of a project-wide deduplicated summary). Drill down to recover
  the full set for a specific MFA.
- The report writer needs every finding for a single high-severity hub
  rather than the capped subset surfaced inline elsewhere.

| Endpoint | Key Fields | Report Section |
|---|---|---|
| `GET /api/intelligence/enrichments?path=P&mfa=Mod.fn/N` | `findings: %{tool => [%{severity, check, message, line, ...}]}` | External Tool Findings |
| `GET /api/intelligence/enrichments?path=P&module=Mod` | same shape, module-scoped findings | External Tool Findings |

**Distinguish the two empty shapes** in commentary:

- `findings: %{}` — no tool has ever been ingested for this project. Tell
  the reader "external-tool enrichments are not configured for this
  project; CI does not run Credo/Dialyzer or has not pushed results to
  `POST /api/index/enrichment`."
- `findings: %{credo: []}` — Credo ran, no findings on this target. The
  presence of the `credo` key is a positive signal (the project IS
  enriched), the empty list means clean per Credo for this MFA.

---

## Report Structure

The report MUST follow this section order. Every section is mandatory unless
the data source explicitly failed (in which case, note the failure).

### Section 1: Executive Summary

A single table with all key metrics. This is the first thing the reader sees.

**Required fields:**
- Source files, Modules, Functions, Types, Specs (with coverage %), Structs, Callbacks
- API surface: total public functions, total private functions, public ratio
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
  2. Alternative: use `api_surface` endpoint which reports public/private per module directly.
  3. Fallback: if both are paginated, grep source files:
     `grep -r "^\s*def " lib/ --include="*.ex"` excluding defp/defmodule/defmacro/defstruct/etc.
  4. Report BOTH numbers: "469 specs / 912 public functions (51.4%)" — never divide by total.
- **API surface ratio**: include the project-wide public/private split from `api_surface`.
  A healthy ratio is typically 30-50% public. Above 70% suggests too many internals are exposed.
  Below 20% suggests over-encapsulation or heavy use of macros.
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
- **Test Coverage Gap Analysis (MANDATORY)**: After the heatmap tables, include a sub-section listing
  ALL modules that lack test files, grouped by reason. Every untested module must have an explanation:
  - Why it has no test (requires daemon, external service, distributed Erlang, etc.)
  - Whether the gap is **actionable** (should be tested, just wasn't prioritized) or **by-design**
    (integration-tested elsewhere, external dependency, or impractical to unit-test)
  - Which untested modules are **quick wins** (standard interface, simple setup)
  - Never leave a test gap unexplained — "no test" without a reason is a red flag for any reader

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
- **Function-level call chains (Build 140+)**: For the #1 risk module, use
  `GET /api/knowledge/logic_flow?from=<caller_MFA>&to=<callee_MFA>&path=<path>` to trace
  one representative call chain from the risk module to a high-fan-in dependent. This shows
  HOW the blast propagates, not just that it does. Include as a sub-section:

  ```
  Call chain: A.foo/2 → C.bar/1 → B.handle/3
  ```

  Skip if logic_flow returns no path (modules connected only via behaviour/protocol dispatch).
- **Migration plan (Build 140+)**: For god modules flagged for splitting in Section 5,
  optionally call `POST /api/knowledge/pre_impact_check` with `action: "rename"` to show
  what callers would break. Include the phased migration steps if the endpoint returns them.
  This is supplementary — do NOT block the report if pre_impact_check is unavailable.

### Section 7: Unprotected Hubs

**Table columns:** Module | In-Degree | Spec Coverage | Severity (red/yellow)

**Rules:**
- Use `unprotected_hubs` endpoint (or extract from `audit` response)
- Only show red and yellow severity (green hubs are adequately protected)
- Add a key insight line: how many specs exist project-wide and where they're concentrated

### Section 8: Coupling Analysis (Top 10 Pairs)

**Table columns:** Caller | Callee | Call Count | Distinct Functions

**Rules:**
- Use `coupling` endpoint, take top 10
- Ignore stdlib coupling (Enum, Map, String, Logger, etc.) — only report project-internal coupling
- If coupling is "by design" (e.g., thin GenServer + pure state module), note it

### Section 9: Dead Code

**Table columns:** Module | Function | Line | Category

**Rules:**
- Use `dead_code` endpoint. Each entry now carries `:category` (`genuine`,
  `test_only`, `library_public_api`, `template_pending`, `uncategorized`) and
  the response carries a top-level `:summary` with `by_category`,
  `irreducible`, and `actionable` counts.
- **Lead the section with the summary line**:
  > "N total flagged dead — `actionable` (genuine + uncategorized), `irreducible`
  > (library_public_api + test_only + template_pending). Of M total functions
  > (X%)."
- **Sort entries by category**: actionable first (`genuine`,
  `uncategorized`), then irreducible (`library_public_api`, `test_only`,
  `template_pending`). The reader cares most about actionable items.
- **Don't manually re-litigate categories.** The classifier already encodes
  "Functions called only via `apply/3` or dynamic dispatch" through the Pass
  10/11 `reference_targets` exemption (entries reaching the dead_code list
  have already been filtered against MFA-tuple, capture, apply, and
  Task.start_link forms). If a finding still lists, the absence is real
  within the static-analysis surface.
- Per-codebase residuals to acknowledge in commentary (not as table rows):
  - `__skills__/0` in SkillRouter — overridden by `@before_compile`. Should
    be exempted via the `@dead_code_ignore` module attribute, not flagged.
  - `template_pending` entries — blocked on slice-a (heex template scanner);
    they remain as honest signal until that ships.
- **External-tool cross-reference**: when entries carry `:enrichments`, name
  the strongest signal in commentary. A function listed here AND with
  Dialyzer `:no_return` or `unused_function` in its enrichments is the
  highest-confidence "delete this" recommendation in the report.

### Section 10: External Tool Findings (Build 156+)

**Conditional section** — include only if `tools_ingested(project) != []`. If
the project has never been enriched (no `POST /api/index/enrichment` calls
landed for it), skip this section entirely.

**Two sub-tables.**

**10a. Errors (severity = `:error`)** — real bugs. Columns: Tool | Check |
Module | Function/Arity (or "module-scope" if `scope: :module`) | Line |
Message.

- Source: walk `dead_code.dead[*].enrichments` AND
  `pre_impact_check.affected_callers[*].enrichments` from any
  pre-impact-checks run during data collection. Deduplicate by
  `{tool, check, module, function, arity}`.
- For uncapped lookups on a specific MFA, use
  `GET /api/intelligence/enrichments?path=P&mfa=Mod.fn/N`.
- **Sort by Tool then Check** so all `Credo.Check.Warning.IExPry` rows
  cluster together — patterns are easier to act on than scattered entries.
- If `:resolution_ambiguous: true`, append `(ambiguous attribution)` to the
  Function column. The finding is real but its function-level attribution
  may be imprecise — most often this means the line resolution surfaced
  multiple candidates with different names.

**10b. Warnings (severity = `:warning`)** — same columns, same source,
sorted the same way. Cap the table at 30 rows; if exceeded, list the
remaining as "+ N more" and reference the per-tool count in commentary.

**Counts header (always)**:

> "Tools ingested: `<list>`. Findings persisted: errors=N, warnings=M,
> info=K (info entries are dropped from this report; for explicit
> drill-down, use `/api/intelligence/enrichments`)."

**Provenance footnote** — ONE LINE per ingested tool:
> "Credo run at `<run_at>` against `<tool_version>`."

If any finding's `provenance.source_digest_at_run` differs from the current
file digest, flag it: "M findings on stale source — re-run the tool and
re-ingest."

**Cross-references**: don't repeat anything from Section 6 (Blast Radius)
or Section 9 (Dead Code) here — those sections already inline enrichments.
This section is the project-wide flat view, complementary to per-module
detail elsewhere. Useful sentence to land:

> "X errors here that also appear in high-blast-radius callers (Section 6)
> are top fix candidates."

### Section 11: Struct Lifecycle

**Table columns:** Struct | Defining Module | User Count | Logic Leaks | Leak Count

**Rules:**
- Use `struct_lifecycle` endpoint (or extract from `audit` response)
- **Logic leaks**: modules that reference a struct but are not the defining module — this is
  a COUPLING METRIC, not an encapsulation violation. Pattern matching on struct fields is
  idiomatic Elixir. The metric tracks how many modules would need updating if the struct
  shape changes — but for app-internal structs, the compiler catches this automatically.
  Only flag as a concern at library/context boundaries where `@opaque` would be appropriate
- Sort by leak_count descending — highest leak count = worst encapsulation
- User Count is the number in the table; list the actual user module names in commentary
  below the table only for structs with leaks > 0 (keeps the table scannable)
- If a struct has 0 users outside its defining module, it's well-encapsulated — no action needed
- If a struct has 0 users total (including its own module), flag as "potentially unused struct"
- Commentary: not all logic leaks are bugs — shared data structures (e.g., `%User{}` across
  contexts) will naturally appear. Flag the pattern, let the reader judge intent.

### Section 12: Semantic Duplicates

**Rules:**
- Use `duplicates` endpoint (or extract from `audit` response)
- Report: "N clusters found at >= X% similarity threshold"
- List top 3 clusters with their similarity score and member function names
- **False positive caveat**: large clusters of accessor functions (`get_x/1`, `set_x/2`),
  delegate functions (`defdelegate`), or simple CRUD wrappers are expected to cluster —
  they share structural patterns, not duplicated logic. Flag these as "structural similarity,
  not duplication" when the cluster members are all accessors/delegates.
- **Mega-clusters with low similarity (< 20%)**: These are threshold artifacts — the algorithm
  groups everything sharing basic language structure (def heads, pipe chains, pattern matches)
  into one cluster. Explain WHY it's noise: "N members at X% similarity means the cluster
  captures nearly all functions sharing basic Elixir structure — threshold artifact, not
  meaningful duplication." Never dismiss with just "noise" or "ignore" — the reader needs to
  understand the mechanism.
- If EmbeddingServing is unavailable (503), note: "Semantic duplicates unavailable — EmbeddingServing not loaded"
- **Transitive cluster bug (fixed Build 138+)**: pre-Build-138 versions may return
  mega-clusters with avg_similarity well below the threshold due to BFS transitive
  expansion. If you see a cluster with avg_similarity < threshold, discard it — it's
  a chain artifact, not real duplication.

### Section 13: Architecture Health

A pass/fail checklist table:

| Check | Status |
|---|---|
| Circular dependencies | 0 — Clean DAG / N cycles found |
| Behaviour integrity | Consistent / N fractures |
| Orphan specs | 0 / N orphans found |
| Dead code | N functions (M genuinely unused) |

**Rules:**
- Cycles > 0 is a P0 issue — list the cycle chains
- Fractures > 0 is a P1 issue — list which behaviours/implementers are broken
- Orphan specs indicate refactoring debris — list them for cleanup
- Behaviour integrity can be extracted from `audit` response instead of a separate call

### Section 14: Runtime Health (if available)

**Table 1:** Processes | Memory | Schedulers | Run Queue | Uptime | ETS Tables

**Table 2 (Hot Spots):** Module | Reductions % | Memory

**Rules:**
- Only include if runtime data is available (self-introspection or connected node)
- Run queue > 0 sustained = scheduler pressure, flag as warning
- Memory > 500MB = investigate, flag largest ETS tables
- Hot spots: top 5 by reductions, note if expected (e.g., supervisor at startup) or anomalous

**Performance Profile (Build 140+):** If `GET /api/runtime/profile/latest` returns a profile,
add a sub-section with:
- Hot modules from burst analysis (top 5 by reductions during the burst window)
- Bottleneck analysis summary (if available)
- Peak metrics vs baseline comparison

This is supplementary to the standard pulse/hot_spots data. The profile captures a specific
burst window, while pulse is a point-in-time snapshot. Both are valuable — pulse for current
state, profile for worst-case behavior.

**Fused Observations (Build 140+):** If `GET /api/runtime/observations` returns sessions,
include a sub-section listing available observation sessions with:
- Session ID, target node, duration, status
- For the most recent completed session, call `GET /api/runtime/observation/:session_id`
  and include the fused profile summary (static analysis correlated with runtime metrics).
  This is the highest-fidelity view available — it maps runtime hot processes back to
  Knowledge Graph modules.

Skip the fused observations sub-section if no sessions exist (monitor hasn't observed any nodes).

### Section 15: Recommended Actions (Priority Order)

Synthesize findings into concrete, prioritized recommendations.

**Priority levels:**
- **P0**: Blocking issues — cycles, behaviour fractures, crashes
- **P1**: High-risk gaps — unprotected hubs, god modules with high fan-in
- **P2**: Improvement opportunities — god module splits, coupling reduction, dead code
- **P3**: Polish — spec coverage for non-hub modules, doc coverage

**Priority ordering within P1 — fan-in dominates:**
A hub module with high fan-in and low doc/spec coverage ALWAYS outranks a low-fan-in module
with zero coverage. The risk multiplier is dependents, not the coverage percentage itself.
Concretely: a 17-dependent module at 4% doc coverage is more dangerous than a 3-dependent
module at 0% spec coverage — because 17 consumers are flying blind vs 3. Sort P1 items by
`in_degree * (1 - coverage_ratio)` descending, not by coverage percentage ascending.

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
8. **Header**: Every report MUST begin with a branding block before Section 1:
   ```
   > **Intelligence delivered by [Giulia](https://github.com/thatsme/Giulia)** — Local-first AI code intelligence for the BEAM.
   ```
9. **Footer**: Always include at the very end of the report:
   ```
   ---
   *Intelligence delivered by [Giulia](https://github.com/thatsme/Giulia) v<version> — <project_path> — <date>*
   ```

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

## **ELIXIR IDIOM RULE (NON-NEGOTIABLE)**

**YOU ARE ANALYZING ELIXIR CODE, NOT JAVA. THINK IN ELIXIR.**

**Pattern matching on struct fields is IDIOMATIC ELIXIR — it is NOT an
"encapsulation leak", NOT an "implementation detail exposure", NOT a
"coupling violation." The Elixir compiler enforces struct shape at compile
time. If a struct changes, `mix compile` catches every breakage instantly.
This is a FEATURE of the language, not a defect.**

**DO NOT frame struct field access, pattern matching, or destructuring as
problems. DO NOT use OOP terminology ("encapsulation", "information hiding",
"Law of Demeter") to describe Elixir data flow. Elixir is not Java.**

**The ONLY time struct coupling matters is at LIBRARY or CONTEXT BOUNDARIES
where `@opaque` types or module-API wrappers are a deliberate design choice.
For app-internal structs within the same codebase — it is a complete non-issue.**

**If you catch yourself writing "leaking implementation details" about struct
pattern matching in Elixir — STOP. Delete it. Rewrite in Elixir terms.**

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
9. **Don't use OOP framing for Elixir code** — no "encapsulation leaks", no "Law of Demeter violations", no "information hiding concerns" for struct pattern matching. This is Elixir, not Java. See the **ELIXIR IDIOM RULE** section above.
10. **Don't call 4 separate endpoints when audit covers it** — use `GET /api/knowledge/audit` for unprotected_hubs + struct_lifecycle + duplicates + integrity. Fall back to individual calls only on error.
