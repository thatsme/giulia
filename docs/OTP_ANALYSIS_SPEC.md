# OTP Deep Analysis — Feature Specification

**Status**: Draft for review · 2026-07-25 · §2 data model revised 2026-07-25 (process-vertex identity, bounded binding resolution, union per registered name)
**Target**: post-v0.4.0 (after inference-subsystem removal)
**Positioning**: Giulia's differentiation play. Credo checks syntax-level style, Dialyzer checks types — nobody statically analyzes *process architecture*. This feature makes Giulia the tool that understands the BEAM's concurrency model, not just its AST.

---

## 1. Motivation

Every check in this spec targets a bug class that: (a) appears in production, not in tests — deadlocks, boot cascades, and mailbox floods are interleaving- and load-dependent; (b) is invisible to existing tooling; and (c) is detectable from data Giulia already extracts (function-level call edges, behaviour-impl edges, callback clause patterns) plus one new builder pass.

The unique angle: Giulia is the only tool holding *both* the static call graph *and* live runtime data (Collector snapshots: message-queue lengths, reductions, memory per process). Several checks below produce a static *suspicion* that runtime data *confirms* — the same AST+runtime fusion pattern `/api/runtime/hot_spots` already implements for CPU, applied to contention.

---

## 2. Foundation: Supervision Topology Extraction (Pass 12)

A new builder pass that extracts the supervision tree from AST.

### What it parses

- `Application.start/2` child lists (including the tiered/conditional idiom — see blind spots)
- `Supervisor.init/1` and `Supervisor.start_link/2` child specs
- Child spec forms: module atom, `{module, args}`, full `%{id:, start:, restart:, ...}` maps, `Supervisor.child_spec/2` overrides
- Strategy per supervisor (`:one_for_one` / `:one_for_all` / `:rest_for_one`), `max_restarts`/`max_seconds` when literal
- `DynamicSupervisor` declarations (children unknowable statically — see blind spots)

### Data model

> **Revised 2026-07-25.** The original draft specified only an edge label and
> assumed both endpoints were existing module vertices. Reading
> `lib/giulia/application.ex` against `Builder.add_module_vertices/2`
> (`builder.ex:170`, vertices keyed by module name from `data[:modules]`)
> disproved that assumption — see "Process vertices — one identity rule" below.

#### Process vertices — one identity rule

Supervision identity is **not** module identity. Three independent facts from
Giulia's own tree break the module-keyed model:

1. **Five process names have no `defmodule`** — including the root.
   `Giulia.Supervisor`, `Giulia.Provider.Supervisor`,
   `Giulia.Core.ProjectSupervisor`, `Giulia.Registry`, `Giulia.TaskSupervisor`
   are registered-name atoms passed as `name:`. None is a graph vertex today,
   so a `:supervises` edge would have no parent to attach to.
2. **Five children are external modules** — `Registry`, `Task.Supervisor`,
   `DynamicSupervisor` (×2) and `Bandit` are filtered out of `all_modules`
   by Pass 2, so they are not vertices either.
3. **The two `DynamicSupervisor`s collide** — both are declared inline as
   `{DynamicSupervisor, name: X}`, so module identity merges
   `Giulia.Provider.Supervisor` and `Giulia.Core.ProjectSupervisor` into one
   node.

One rule governs **both** endpoints of every `:supervises` edge:

```
process vertex key = name_option || module
```

New vertex type `:supervisor` for anything that supervises. Supervised leaves
follow the same key rule, reusing the existing `:module` vertex whenever the
key resolves to a project module.

> **Hard rule — never re-label an existing vertex.** libgraph *accumulates*
> labels: a second `Graph.add_vertex(g, v, :supervisor)` on a vertex that
> already carries `:module` yields `[:module, :supervisor]`. Membership filters
> (`:module in labels` — `metrics.ex:48,167`, `reader.ex:334,417`,
> `topology.ex:171`) survive that, but **exact-equality filters silently stop
> seeing the vertex**: `topology.ex:39` (hub ranking), `topology.ex:126`
> (fuzzy-match suggestions), `insights.ex:77` (in-neighbour filtering).
>
> Therefore Pass 12 mints the `:supervisor` label **only for vertices it
> creates** — registered names (`Giulia.Supervisor`) and external modules
> (`Bandit`, `Registry`), none of which any existing filter sees today.
> Project modules that happen to be supervised keep `[:module]` untouched.
> Regression surface: zero. Cycle detection (`topology.ex:171`) uses
> membership and is unaffected either way.

| attr | meaning |
|---|---|
| `module` | implementing module (`Registry`, `DynamicSupervisor`, `Giulia.Knowledge.Store`), or `nil` |
| `registered_name` | the `name:` atom, when present |
| `external` | `true` when `module` is not a project module (`Bandit`, `Registry`, `Task.Supervisor`, …) |
| `dynamic` | `true` for `DynamicSupervisor` — children unknowable statically |
| `strategy`, `max_restarts`, `max_seconds` | when literal |
| `children_unresolved` | `true` when the child list could not be statically bounded (see below) |

This resolves all three facts at once: the root exists, the two
`DynamicSupervisor`s stay distinct, `{Task.Supervisor, name: Giulia.TaskSupervisor}`
and `{Registry, name: Giulia.Registry}` get stable identities, and external
supervisors become representable.

#### Edge

```
{:supervises, %{restart: :permanent | :transient | :temporary | :unknown,
                order: n,
                strategy: parent_strategy,
                conditional: boolean}}
```

`conditional: true` marks children inside `if`/`case`/comprehension in the child-list construction (Giulia's own `application.ex` builds tiers conditionally on `GIULIA_ROLE` — the pass must capture the *union* of children and flag conditionality, mirroring the `elixirc_paths` union approach in `ScanConfig.mix_exs_roots/1`).

#### Bounded binding resolution

Child lists are rarely literal arguments. Giulia's own call is
`Supervisor.start_link(children, opts)`, where `children` traces back through
`all_children = base_children ++ heavy_children ++ inference_children ++ tail_children ++ mcp_children`,
each assigned in its own `if`. The pass therefore resolves bindings — but
within a hard boundary:

**In scope** (resolve):
- single-assignment variables in the enclosing function
- literal lists
- `++` concatenation chains

**Out of scope** (do not guess):
- function calls, `Enum.*` / comprehension-built lists, config- or
  env-driven lists, anything requiring cross-function or cross-module tracing

On anything out of scope the pass emits the supervisor vertex with
`children_unresolved: true` and **no** child edges. A partial child list
silently presented as complete is worse than an explicit gap: every downstream
check in §3 reasons over this tree, so an unmarked omission becomes a false
negative in the deadlock detector. Recorded in ARCHITECTURE §18.

#### Union per registered name

A single registered name may be started from multiple `Supervisor.start_link`
call sites. `Application.start/2` has exactly this shape: the `client_mode?()`
branch starts `Supervisor.start_link([], strategy: :one_for_one, name: Giulia.Supervisor)`
— **empty children, same name as the daemon branch**.

Children are therefore **unioned per registered name across all call sites**,
never taken from the first match.

This is a required *negative* test, not merely a rule to observe: a pass that
latches onto the `client_mode?()` branch returns an empty tree and passes every
positive assertion written about it. The Phase 1 suite must assert that the
client-mode branch is parsed and contributes **zero** children, *and* that the
daemon branch contributes the full tier set — the empty-tree failure mode is
asserted against by name.

### Deliverables

- `GET /api/knowledge/supervision?path=P` — tree as nested JSON + flat edge list, Cytoscape-ready
- Graph Explorer: fifth view mode "Supervision" (tree layout, nodes colored by restart type, DynamicSupervisors marked)
- MCP tool `knowledge_supervision` (auto-generated via `@skill`, REST/MCP parity test extends for free)

### Known blind spots (document in ARCHITECTURE §18 from day one)

| Pattern | Why invisible | Mitigation |
|---|---|---|
| DynamicSupervisor children | Started at runtime via `start_child/2` | Emit the supervisor vertex with `dynamic: true`; join call-sites of `DynamicSupervisor.start_child` for a best-effort child-type hint |
| Child lists built from config/env | Data computed at boot | `conditional: true` flag; union of all branches |
| Registry-based via-tuples | Process identity is runtime data | Module-level resolution only; confidence flag on dependent checks |
| Child list built by function call, `Enum.*`, or comprehension | Outside the bounded binding resolution (single-assignment vars, literal lists, `++` chains, enclosing function only) | Supervisor vertex emitted with `children_unresolved: true` and no child edges — an explicit gap, never a partial list presented as complete |
| Children of external supervisors (`Registry`, `Task.Supervisor`, `Bandit`) | Defined in dependency source, outside the scanned project | Vertex emitted with `external: true`; tree stops there, not traversed into deps |

---

## 3. Check Catalog

Each check ships with the filter-accountability test pattern (drop-side fixtures parametric over the criteria + strictly-larger pass-through set) and a self-scan baseline entry. Severities align with the conventions engine tiers.

### 3.1 `blocking_init` — severity: error

**Detects**: blocking calls inside `init/1` of a GenServer/Supervisor (or reachable from it through same-module private helpers).

**Why it matters**: `init/1` runs inside the supervisor's start sequence. A blocking call serializes boot, and a down dependency turns into restart-intensity cascade — the supervisor gives up and the tree dies. Idiomatic fix: return `{:ok, state, {:continue, :load}}` and do the work in `handle_continue/2`.

**Detection**: walk `init/1` body (Pass 4 machinery) + intra-module transitive closure of private helpers called from it. Flag calls whose MFA matches the blocking list in `priv/config/otp_checks.json`:

- Network: `Req.*`, `HTTPoison.*`, `Finch.request`, `Tesla.*`, `:httpc.*`, `:gen_tcp.connect`
- DB: `*.Repo` calls (Ecto naming convention), `Postgrex.*`, `MyXQL.*`
- Cross-process: `GenServer.call/2,3`, `:gen_server.call`, `Task.await`
- Sleep: `Process.sleep`, `:timer.sleep`
- Tiered: network/DB/cross-process = error; `File.*` reads = warning (config reads at boot are legitimate and size is unknowable)

**False positives**: fast local reads misclassified. Mitigations: the File tier at warning, the existing `?suppress=` mechanism, and `handle_continue` presence in the same module noted in the finding (author already knows the idiom → likely intentional).

**Effort**: ~1 day + tests. Pure AST, reuses body-walk machinery.

### 3.2 `cross_process_call_cycle` — severity: error (P0 in reports)

**Detects**: cycles in the *synchronous inter-process call graph* — module A's `handle_call/3` (or code reachable from it) performs `GenServer.call` targeting module B, and B's `handle_call` path calls back into A.

**Why it matters**: this is a guaranteed deadlock when the cycle fires — A blocks waiting on B, B blocks waiting on A, both die by timeout 5 seconds later with confusing stack traces. It only manifests under the specific interleaving, so tests rarely catch it.

**Detection**:
1. Identify GenServer implementer modules (behaviour-impl edges — already exist).
2. Build the subgraph: edges originate in `handle_call/3`, `handle_cast/2`, `handle_continue/2` bodies (+ intra-module closure), and are `GenServer.call`/`GenServer.multi_call` invocations whose target resolves to another implementer module.
3. Run existing SCC cycle detection (`Topology`) on this subgraph.

**Confidence levels** (module ≠ process; static analysis sees modules): `high` when both endpoints are `name: __MODULE__` singletons (module identity = process identity); `medium` otherwise (multiple instances may make the cycle safe). Report both, severity error only for `high`.

**Effort**: ~1.5 days. The subgraph filter is new; cycle detection is a call into existing code.

### 3.3 `sync_call_chain_depth` — severity: warning

**Detects**: acyclic synchronous call chains of depth ≥ 3 through the same subgraph as 3.2.

**Why it matters**: every hop carries a default 5s timeout; a 3-hop chain is a 15s worst-case latency budget nobody approved, and timeout failures surface at the *outermost* caller, far from the slow hop. Finding includes the full chain with per-hop timeout (default or explicit) and the summed budget.

**Effort**: ~0.5 day on top of 3.2 (longest-path over the same subgraph, depth-capped).

### 3.4 `singleton_bottleneck` — severity: warning (static) / error (runtime-confirmed)

**Detects**: a `name: __MODULE__` (or registered-atom) GenServer receiving synchronous calls from N+ distinct caller modules (default threshold: 8, config-driven).

**Why it matters**: a singleton serializes every caller. High static fan-in is a *suspicion* of a contention point; it becomes a *finding* when runtime agrees.

**Runtime fusion**: when Collector snapshots exist for the analyzed node, join by registered name: max `message_queue_len` and reduction share during the last burst window attach to the finding. Static suspicion + observed queue depth ≥ threshold (default 100) escalates severity to error. This is the `hot_spots` fusion pattern applied to contention — worth a dedicated response field so reports can say "statically suspected, runtime-confirmed."

**Effort**: ~1 day static + ~1.5 days fusion (IngestStore join, response shape).

### 3.5 `missing_catch_all_handle_info` — severity: warning

**Detects**: a GenServer that defines ≥1 `handle_info/2` clause but no catch-all final clause (bare variable or `_` head, unguarded).

**Why it matters**: `use GenServer` injects a default `handle_info` that logs unexpected messages — but defining *any* clause overrides the injected default entirely. From that moment, a late `Task` reply, a `:DOWN` message, or port noise crashes the server. This is the classic once-a-month-in-production, never-in-tests bug.

**Detection**: precise from clause patterns already extracted. Fires only when clauses exist and none is catch-all — modules defining no `handle_info` keep the injected default and are clean.

**False positives**: near zero. A deliberate let-it-crash-on-unknown-message policy is expressible via `?suppress=`.

**Effort**: ~0.5 day.

### OTP residual baseline — Giulia self-scan (Phase 2, 2026-07-25)

187 files, 187 modules. Recorded honestly: thresholds were not tuned to reach
zero. Plug / Bandit / Plausible runs are still outstanding — this table covers
the self-scan only.

| Check | Findings | Notes |
|---|---|---|
| `blocking_init` | **0** | Includes `Persistence.WarmRestore` clean, which is this check's designated negative case — it defers I/O via a `send/2` self-message, so a flag there would mean the check is wrong |
| `missing_catch_all_handle_info` | **9** | All warning tier. Spot-checked 4 of 9 against source: 0 false positives |
| `cross_process_call_cycle` | **0** | Verified, not assumed — see below |
| `sync_call_chain_depth` | **0** | Same: the subgraph is empty, so there is nothing to chain |
| `singleton_bottleneck` | **0** | Correct, and for a specific reason — see below |
| `infinity_call_timeout` | **1** | `Core.ContextManager:50` — `GenServer.call(__MODULE__, {:init_project, …}, :infinity)`. True positive |
| `one_for_all_amplification` | **0** | Giulia uses `:one_for_one` throughout |
| `unlinked_start` | **0** | Giulia uses `start_link` throughout |

Supervision extraction cross-check: Pass 12 finds 4 supervisors —
`Giulia.Supervisor` (29 children, `one_for_one`, fully resolved),
`Giulia.Inference.Supervisor` (1 child), and the two DynamicSupervisors
(`Provider.Supervisor`, `Core.ProjectSupervisor`) as distinct childless
vertices. The 29 matches a hand-count of `application.ex` exactly
(12 + 2 + 5 + 8 + 1 + 1), across all five tiers plus the conditional Bandit.

#### Phase 3's zero is a verified property, not an empty check

The sync inter-process subgraph has **0 edges** on Giulia. A zero from a
predicate-heavy check is exactly where a silent false negative hides, so it was
checked against source by exhaustion rather than accepted:

- 71 `GenServer.call` sites in `lib/`
- 69 are `GenServer.call(__MODULE__, …)` client-API wrappers or
  `GenServer.call(pid, …)` — self-targeted or non-literal, both correctly
  outside the subgraph
- 1 targets another literal module (`Knowledge.Store`, from
  `inference/rename_mfa.ex:473`) — but that module has no `use GenServer` and no
  callbacks, and the call sits in a plain public function. A client call cannot
  deadlock, so excluding it is correct

Giulia's GenServers do not call each other synchronously from inside callbacks.
That is a real architectural property, consistent with `Knowledge.Store.Reader`
existing precisely to bypass the GenServer for bulk reads.

**Consequence for the baseline:** this codebase cannot regression-test the cycle
detector, because it has no cycles to find. The deliberate two-GenServer
deadlock fixture in `otp_sync_test.exs` is therefore the only standing proof
that the check fires at all — treat it as load-bearing, not illustrative. Runs
against Plug / Bandit / Plausible are still outstanding and are the way to get
real-world positives.

#### `singleton_bottleneck`: why `Knowledge.Store` is correctly NOT flagged

The Phase 4 brief predicts `Knowledge.Store` and `Context.Store` as the
singleton-bottleneck candidates, "high fan-in by design". The check reports
neither, and that is the right answer — the prediction measures a different
quantity.

| | `Knowledge.Store` |
|---|---|
| modules referencing it | 19 |
| `defdelegate … to: Reader` (bypass the process) | 31 |
| `GenServer.call(__MODULE__, …)` sites | 4 |
| distinct modules calling those 4 | **4** (threshold 8) |

Module fan-in and *synchronous process* fan-in diverge here, and the divergence
is the whole point: `Store.Reader` exists precisely so bulk reads go straight to
ETS instead of queueing on the GenServer. Those 31 delegated functions never
touch the process, so counting their callers would report a bottleneck that was
deliberately engineered away.

A check that flagged `Knowledge.Store` would be measuring "how popular is this
module", not "how much serialises through this process". The mitigation is real
and the check confirms it works. Recorded here because a future reader comparing
against the brief will otherwise read this zero as a missing finding.

The nine: `Storage.Arcade.Consolidator`, `Inference.Orchestrator`,
`Persistence.Writer`, `Core.ContextManager`, `Inference.Pool`,
`Persistence.WarmRestore`, `Inference.Approval`, `Core.ProjectContext`,
`EtsKeeper`.

Three worth acting on rather than suppressing:

- `EtsKeeper` — sole clause is `{:"ETS-TRANSFER", …}`. It is the heir process
  for tables whose owners can crash; if an unmatched message kills it, the
  tables it is holding go with it.
- `Persistence.WarmRestore` — sole clause is `:run`, the message it sends
  itself. Anything else crashes boot-time L1↔L2 restore.
- `Core.ContextManager` — sole clause is `{:DOWN, …}`. A crash takes request
  routing down for every project.

`Inference.Pool` is the instructive one: three clauses including
`{ref, result} when is_reference(ref)`, so the author clearly anticipated late
`Task` replies — and still has no catch-all, so monitor noise or a `:timeout`
still crashes the pool. It also confirms the guard semantics: that clause is
correctly *not* counted as a catch-all, because the guard is what makes it
selective.

### Final Validation — live daemon, 2026-07-26

Run through the real pipeline (`/api/index/scan` → `Context.Store` →
`Builder.build_graph/1` → ETS → facade → HTTP), not the test harness. Plug and
Bandit are ordinary Elixir codebases used here purely as analysis inputs.

| Project | Files | Supervisors | Supervised | Root | otp_risks |
|---|---|---|---|---|---|
| Giulia | 189 | 4 | 30 | `Giulia.Supervisor` | 10 (9 warning, 1 info) |
| Plug | 44 | 2 | 3 | `Plug.Application` | 1 warning |
| Bandit | 67 | 1 | 1 | `Bandit.Application` | 0 |

Plausible was skipped: that checkout has no `mix.exs`, so it scanned 0 files.
Correct behaviour, not a scanner defect.

**Giulia's tree matches `application.ex` exactly** by hand-inspection — 29
children in source order, `conditional: true` on precisely tiers 2/3/5 plus
`Bandit`, which is the Phase 1 acceptance criterion satisfied through the live
pipeline. `blocking_init` is 0, with `Persistence.WarmRestore` clean: the
brief's designated negative case, where a flag would mean the check is wrong.

**Plug's one finding is a true positive.** `Plug.Upload.Supervisor.init/1` calls
`File.cwd!()`, flagged at warning tier rather than error — exactly the tiering
intent, since a cheap local read at boot is legitimate but worth inventorying.

**Bandit's zero is honest but weak evidence.** Its real supervision lives in
Thousand Island, a dependency outside the scan, so the tree correctly stops at
`Bandit.Application → Bandit.Clock`.

#### Two defects this run caught that the entire test suite missed

**1. `name: __MODULE__` produced a fabricated root.** `__MODULE__` parses as
`{:__MODULE__, meta, ctx}`, which matched the *variable* clause in
`resolve_expr/3` (`:__MODULE__` is an atom, so is the context), found no
binding, and returned the `:unresolved` sentinel — which `render_name/2` then
rendered as a process literally named `":unresolved"`.

This is the most common supervisor-naming idiom in Elixir. It survived because
every fixture used an alias (`name: Demo.Sup`) and so does Giulia's own
`application.ex` (`name: Giulia.Supervisor`) — the self-scan and the golden
fixtures were structurally incapable of catching it. Only third-party code did.
Regression test added.

**2. `supervisor_count` contradicted its own tree.** It counted edge *sources*,
so DynamicSupervisors — childless by construction — were excluded: Giulia
reported 2 supervisors while displaying 4. Now the union of edge sources and
`:supervisor`-labelled vertices. Still a documented lower bound, because Pass 12
never re-labels an existing vertex, so a supervisor that is also a project
module keeps `[:module]` alone and is counted only if it has children.

The general lesson, consistent with the `singleton_bottleneck` fan-in bug in
Phase 4: **a self-scan validates against one codebase's idioms.** Both bugs were
invisible to fixtures written by the same person who wrote the checks.

### 3.6 Cheaper heuristics — severity: info

Slot into the existing Tier 2 conventions engine as an `otp_deep` rule family, no new machinery:

- `infinity_call_timeout` — `GenServer.call(_, _, :infinity)`; legitimate for long operations, worth an inventory
- `one_for_all_amplification` — `:one_for_all` strategy with > 5 children (config threshold): one crash restarts everything; usually `:rest_for_one` or a split is intended
- `unlinked_start` — `GenServer.start`/`Agent.start` (not `start_link`) outside test code: orphan process, invisible to the tree (complements the existing `unsupervised_task` rule)

**Effort**: ~1 day for all three.

---

## 4. API Surface

| Endpoint | Returns |
|---|---|
| `GET /api/knowledge/supervision?path=P` | Supervision tree (nested + flat edges + per-supervisor strategy) |
| `GET /api/knowledge/otp_risks?path=P` | All catalog findings, grouped by check, with severity, confidence, and runtime-confirmation fields |
| `GET /api/knowledge/otp_risks?path=P&check=cross_process_call_cycle` | Single-check filter |

Both route through the Knowledge facade (coercion/defaults live once, REST/MCP parity holds by construction). Findings reuse the conventions response shape (`by_severity`, `by_category`, `suppressions_applied`) so report tooling and the MCP layer inherit them.

**REPORT_RULES**: new Section 15b-adjacent "Process Architecture" section — supervision tree summary, cycle findings (P0), blocking-init findings (P1), runtime-confirmed bottlenecks. Deadlock cycles join cycles/fractures in the P0 tier of Section 16.

## 5. Configuration Surface

New `priv/config/otp_checks.json`:

```json
{
  "blocking_init": {
    "error_mfas":   ["Req.*", "HTTPoison.*", "Finch.request", "Tesla.*",
                     ":httpc.*", ":gen_tcp.connect", "GenServer.call",
                     "Task.await", "Process.sleep", ":timer.sleep"],
    "warning_mfas": ["File.*"],
    "repo_convention": true
  },
  "sync_chain":         { "max_depth": 2 },
  "singleton_bottleneck": { "fan_in_threshold": 8, "queue_len_threshold": 100 },
  "one_for_all":        { "max_children": 5 }
}
```

Per the config contract: loader module with `:persistent_term` cache, fail-loud on malformed, **added to `CodeDigest.@tier_config_files` in the same commit** (lesson from the dispatch_invariants gap — the digest omission class is now a known failure mode; make it a checklist item for every new config file).

Universal-defaults principle applies: shipped thresholds must produce sane output on Plausible/Plug/Bandit/Giulia with zero tuning, verified before release.

## 6. Testing Strategy

- **Filter-accountability per check**: drop-side fixtures parametric over each predicate + strictly-larger pass-through sets (the pattern that caught 11 over-match bugs on first deployment — these checks are predicate-heavy, exactly its territory).
- **Golden fixtures** for Pass 12: freeze extraction output for curated supervision shapes — flat tree, nested supervisors, conditional children (Giulia's own tiered `application.ex`), DynamicSupervisor, child_spec overrides.
- **Self-scan baseline**: Giulia's own tree is the first target (5 tiers, conditional children, known singletons: `Knowledge.Store`, `Context.Store`). Expected findings become the residual baseline, alongside Plausible/Plug/Bandit runs, mirroring the dead-code canonical-residuals table.
- **One deliberate deadlock fixture**: two toy GenServers calling each other in `handle_call`, asserted as `high` confidence cycle — the check's reason for existing, frozen as a test.

## 7. Sequencing

| Phase | Content | Effort | Payoff |
|---|---|---|---|
| 1 | Pass 12 + `/supervision` endpoint + Explorer view | 2–3 days | Immediate visual value; foundation for everything |
| 2 | `blocking_init` + `missing_catch_all_handle_info` | 1.5 days | Pure AST, high signal, near-zero FP — trust builders |
| 3 | Call-subgraph checks: cycle, chain depth, singleton (static) | 2.5 days | The P0 detector; the feature's headline |
| 4 | Runtime fusion for singleton confirmation | 1.5 days | The "only Giulia can do this" moment |
| 5 | Info-tier heuristics + REPORT_RULES section + docs | 1 day | Completeness |

Total ≈ 9 working days. Phases 1–2 are independently shippable; each phase leaves the tool strictly better.

## 8. Out of Scope (explicitly)

- Runtime deadlock *detection* (that's the observer's job; we do static *prediction*)
- Cross-node call analysis (module resolution across releases is a different problem)
- Mailbox growth prediction from send-rate analysis (research-grade; revisit after fusion ships)
- Any non-BEAM language (this feature is the argument *against* the tree-sitter roadmap item)
