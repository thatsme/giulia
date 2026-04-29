# Changelog

All notable changes to Giulia that affect observable behavior, API contracts,
analysis output correctness, or cached-data compatibility. Internal refactors
and test-only changes are not listed here — see the git log for those.

## [0.3.8 – Build 161] — 2026-04-29 — Config-driven dispatch invariants + relevance filter on noisy endpoints

Two slices, both user-visible.

### `?relevance=high|medium|all` on `dead_code`, `conventions`, `duplicates`

A single shared parameter that lets clients trade noise for signal on
the three highest-volume listing endpoints. Invariant: missing or
unrecognised value → `all` (current default — fully backwards compatible).

  - `/api/knowledge/dead_code?relevance=high` → only `:genuine` entries.
    `medium` → `:genuine + :uncategorized` (matches existing `actionable`
    rollup).
  - `/api/knowledge/conventions?relevance=high` → only `severity: "error"`
    violations. `medium` → error + warning. Filter applies to `by_file`
    grouping and recomputes `total_violations` + `by_severity` +
    `by_category` so the response shape stays consistent with the
    unfiltered call.
  - `/api/knowledge/duplicates?relevance=high` → tightens the cosine
    threshold to **0.95** (very-likely true duplicates). `medium` → 0.90.
    A user-supplied `?threshold=` HIGHER than the bucket wins (relevance
    can only tighten, never loosen).

Same `relevance` arg available on the equivalent MCP tools
(`knowledge_dead_code`, `knowledge_conventions`, `knowledge_duplicates`).
Bucket boundaries live in `priv/config/relevance.json` and are tunable
without recompile — same persistence pattern as `ScoringConfig` /
`DispatchPatterns` / `DispatchInvariants` / `ScanConfig`.

Closes a long-standing LLM-context-pollution complaint: agents asking
for `dead_code` against a large project no longer have to manually
filter `library_public_api` / `test_only` rollups out of the response
before reasoning about it.

### Config-driven dispatch invariants (closes 2f)

Four module attributes that previously hardcoded dispatch-time data
in `.ex` source moved to `priv/config/dispatch_invariants.json`:

  - `@project_markers` (Indexer)
  - `@implicit_functions` (Metrics — OTP/framework callbacks exempted from dead_code)
  - `@known_behaviour_callbacks` (Behaviours — 24 stdlib/ecosystem behaviour signatures)
  - `@router_verbs` (Builder + Metrics — Phoenix HTTP verbs; previously DUPLICATED across two modules)

All four read through `Giulia.Config.DispatchInvariants` (persistent_term
cache, mirrors `ScoringConfig` shape). The `@router_verbs`-in-guard
sites refactored to runtime check (`is_atom(verb) and is_atom(action)`
guard + `router_verb?/1` body call) so the convention "JSON edit +
daemon restart, no recompile" applies uniformly.

### Hermetic test compose

Independent of the two slices above, `docker-compose.test.yml` was
audited for precondition violations against prod state and corrected:

  - Top-level `name: giulia-test` → its own compose project + own
    default network. No more shared `giulia_default` with prod.
  - Volumes renamed `giulia_deps` → `giulia_test_deps`,
    `giulia_models` → `giulia_test_models`. The four-volume layout is
    now mechanically incapable of touching prod state
    (`giulia_data`, `giulia_build`, `giulia_deps`, `giulia_models`).
  - `down -v` on the test compose can no longer wipe prod caches.

Test ritual collapsed from 4 steps (pre-flight, stop prod, run, teardown)
to 3 (pre-flight, run, teardown). Prod stays up during tests.

### Deprecated

The early-v0.x local-chat inference subsystem is **deprecated as of v0.3.8**
and will be removed in v0.4.0. Giulia's canonical role is the read-only
data surface (REST + MCP); the LLM lives in the client (Claude Code,
Claude Desktop, anything that speaks REST or MCP). The internal
Observe-Orient-Decide-Act loop, LLM-provider tree, and write-tool
dispatch were appropriate for early-v0.x's local-chat mode but no
longer the product.

The deprecation set (still loads, still responds — backwards compatible
for any user who wired a workflow against the legacy endpoints):

- `lib/giulia/inference/` — 32 modules (`Inference.Pool`,
  `Inference.Approval`, `Inference.Events`, `Inference.Trace`,
  `Inference.Supervisor`, `Inference.ContextBuilder`,
  `Inference.ToolDispatch`, `Inference.Transaction`,
  `Inference.Escalation`, `Inference.RenameMFA`,
  `Inference.BulkReplace`, `Inference.Verification`, …)
- `lib/giulia/provider/` — 6 LLM provider modules
  (Anthropic, Gemini, Groq, LM Studio, Ollama, Router)
- HTTP endpoints `POST /api/command`, `POST /api/command/stream`,
  `/api/approval/*`, `/api/transaction/*`
- MCP tools under `approval_*` and `transaction_*` prefixes
- Write-tools `lib/giulia/tools/{patch_function,bulk_replace,rename_mfa}.ex`
- Compose env vars `LM_STUDIO_URL`, `ANTHROPIC_API_KEY`,
  `GROQ_API_KEY`, `GEMINI_API_KEY`

Documentation aligned: README.md repositioned ("Giulia is the eyes,
not the brain"); ARCHITECTURE.md TIER 3 marked deprecated, OODA-loop
references removed, Section 18 (Known Blind Spots) gains a deprecated-
subsystem note, Section 10 (MCP Layer) opens with the canonical
external-client integration model.

## [0.3.7 – Build 160] — 2026-04-29 — Protocol-shim discipline, self-scan SIGSEGV fix, verifier parity

Three independent slices in one release. Each closes a class of
silent-correctness or operational issue surfaced by the v0.3.x
architectural cleanup.

### MCP dispatch split + orchestration lift (commits `02bd92f` + corrective lift)

`Giulia.MCP.Server` collapsed from 1061 → 118 lines. Tool dispatch is
now table-driven via `Giulia.MCP.ToolSchema.handler_for/1` — tool
name maps to `{Module, function}` in the matching
`Giulia.MCP.Dispatch.<Category>` module via prefix routing, with
`String.to_existing_atom/1` + `function_exported?/3` guards. The 12
per-prefix `handle_tool_call` heads and 71 per-category
`defp dispatch_*` clauses are gone, replaced by a single head.

**Crucially**, the dispatch modules are NOT a place for orchestration.
Every multi-step composite now lives in the business-logic layer, and
both HTTP routers and MCP dispatchers reduce to a SINGLE call:

  - `Giulia.Knowledge.Store.audit/1` (was 4-sub-call composite duplicated in router + dispatch)
  - `Giulia.Knowledge.Store.integrity_report/1` (was triplicated; `format_fracture` was missing the `{name, arity}` → `"name/arity"` step on the MCP path — clients got tuples, HTTP got strings)
  - `Giulia.Knowledge.Store.topology_view/1` (was DIVERGENT — HTTP used rolled-up edges from v0.3.5, MCP used flat: same operation, different output)
  - `Giulia.Knowledge.Store.format_fracture/1` (single source of truth)
  - `Giulia.Persistence.Store.verify_cache/1` (Merkle/CubDB cascade)
  - `Giulia.Persistence.Verifier.verify_l2/2` (composite over graph/ast/metrics)
  - `Giulia.Context.Indexer.status_with_cache/1`
  - `Giulia.Context.Store.Query.functions_by_complexity/2`
  - `Giulia.Enrichment.Ingest.run_with_validation/3`

Closes the MCP "tools/list ↔ tools/call" gap from v0.3.x: 4 declared
tools that silently 404'd via MCP are now wired through to the same
business-logic functions: `index_enrichment`, `intelligence_enrichments`,
`knowledge_verify_l2`, `knowledge_verify_l3`. Test invariant
`Giulia.MCP.ToolSchema.unhandled_tools()` must return `[]` — pinned
by `tool_schema_handler_test.exs`.

Two preexisting bugs surfaced and fixed by the new dispatch tests:
`Dispatch.Runtime.connect` (case clauses matched a tuple shape that
`Daemon.Helpers.safe_to_node_atom/1` never returns — every MCP
runtime_connect call crashed with CaseClauseError) and
`Dispatch.Runtime.profile_latest` (atom mismatch
`:no_profiles` vs the actual `:not_found` returned by Monitor).

### Self-scan SIGSEGV fix (commit `350da83`)

`Indexer.scan/1` triggered `mix deps.get` + `mix compile` subprocesses
via `ensure_compiled/1` to give the project an isolated build path
for xref analysis. When the project being scanned was the same source
tree the running BEAM was launched from (e.g., `mix test` running on
the Giulia codebase scanning `/projects/Giulia`), the inner Mix shared
`mix.lock`, `deps/`, and `.fetch` markers with the outer Mix process.
Under ARM64 / OrbStack this SIGSEGV'd the BEAM (exit 139) every time,
right after xref completed. Integration tests had been failing
silently at boot for weeks.

  - `Giulia.Context.Indexer.self_scan?/1` detects when
    `Path.expand(project_path) == Path.expand(File.cwd!())`. On true,
    `ensure_compiled/1` logs and returns `:ok` without spawning sub-mix.
  - `Giulia.Knowledge.Builder.find_beam_directory/1` falls back to
    `Mix.Project.build_path/0` for self-scans so xref reads the outer
    Mix's already-compiled BEAMs.
  - `Builder.giulia_build_path/1` (private duplicate) deleted; both
    modules now share `Indexer.giulia_build_path/1`.

**Prod unaffected**: prod runs the daemon binary (not `mix test`), so
`cwd != project_path` and the normal sub-mix path stays.

Verified: 52/52 integration tests pass (was 0 — process died at boot).

### verify_l2 + verify_l3 cross-store parity (commit `1b5d78c`)

Both verifier endpoints reported `overall: fail` on a clean,
fresh-scanned project — useless as CI signal. Two independent root
causes, both fixed:

**verify_l3 — count_parity always reported `l3_exceeds_l1`.**
`Storage.Arcade.Verifier.count_l3_calls/1` summed CALLS edges across
ALL build_ids; L1 only ever holds the CURRENT build's edges. Comparing
cumulative L3 vs current L1 was structurally guaranteed to mismatch.
`count_l3_calls/1` now scopes to the most-recent build_id (two queries:
`max(build_id)` then count — nested SELECT was unstable on large CALLS
tables, timing out under load).

**L3 history accumulation — exposed by the fix above.**
`Client.delete_edges_for_build/3` is build-id-scoped (purges duplicates
of the same snapshot, not history). `Storage.Arcade.Consolidator` was
a Build-137 skeleton that ran a 30-min timer and did nothing. Replaced
with real pruning:

  - `Giulia.Storage.Arcade.Client.delete_edges_older_than/3` — new
    low-level, mirrors `delete_edges_for_build/3` with `< keep_from`.
  - `Giulia.Storage.Arcade.Consolidator.prune_old_builds/2` — keeps
    the most-recent N builds of CALLS + DEPENDS_ON edges per project;
    deletes the rest.
  - `Consolidator.run_consolidation/1` now actually prunes (was a no-op).
  - `Giulia.Context.ScanConfig.arcade_history_builds/0` reads
    `arcade_history_builds` from `priv/config/scan_defaults.json`
    (default `10`, clamped to ≥3 because drift / coupling / hotspot
    detectors require ≥3 builds of history).
  - `POST /api/index/compact?include=arcade` triggers immediate
    prune for a single project on demand.

**verify_l2 — 80 files missing in L2 on cold-rescan.**
`Persistence.Writer.clear_project/1` was an async cast that spawned a
Task to delete CubDB keys. `do_scan/1` calls `clear_asts/1` (which
casts `clear_project`) then immediately starts streaming `persist_ast`
casts for each scanned file. The async clear iterator overlapped with
the freshly-persisted entries and deleted them too — observed as 30-80
files missing in L2 right after `scan_complete`.

  - `clear_project/1` is now a synchronous `GenServer.call`. The CubDB
    iteration runs inside the writer's `handle_call`, so subsequent
    `persist_ast` casts in the writer's mailbox are guaranteed to land
    AFTER clear completes.
  - `Giulia.Persistence.Writer.flush_now/1` — synchronous per-project
    flush of the 100ms-debounce pending map. Called by
    `Indexer.run_post_scan_pipeline/1` before downstream stages read
    L2 (verifiers, debug tooling). Closes the second-order race.

### Verified end-to-end on `/projects/giulia` after fresh rescan

```
verify_l2.check=all  -> overall: pass
  graph: pass, ast: pass (L1=180=L2=180), metrics: pass
verify_l3            -> overall: pass
  count_parity: match (L1=L3=1863)
  sample_identity: pass across all 7 buckets
```

Both verifier endpoints are now actual CI signals — they go red only
on real cross-store divergence, not on the structural artifacts that
were drowning the signal before. Wiring `verify_l2` / `verify_l3`
into a hard CI gate is now viable (was previously gated on this slice).

### New API surface

  - `POST /api/index/compact?include=arcade` — opt-in body param to
    also prune stale build_id rows from ArcadeDB. Without `include`,
    behavior is unchanged (CubDB compaction only).

### New config field

  - `priv/config/scan_defaults.json` gains `arcade_history_builds`
    (default `10`, clamped ≥3). Tunes the Consolidator's retention
    window. `$schema_version` bumped from 3 to 4.

### Test coverage

  - `test/giulia/mcp/dispatch/helpers_test.exs` — 18 adversarial cases
    on argument-coercion helpers shared across all dispatch modules.
  - `test/giulia/mcp/dispatch/required_params_test.exs` — 60 required-
    parameter accountability cases across 9 dispatch modules.
  - `test/giulia/mcp/tool_schema_handler_test.exs` — 17 handler-routing
    + atom-leak resolver tests, including the
    `assert [] = ToolSchema.unhandled_tools()` invariant.
  - `test/giulia/knowledge/store_format_fracture_test.exs` — pins the
    canonical `{name, arity}` → `"name/arity"` shape.
  - `test/giulia/context/indexer_self_scan_test.exs` — 5 cases on
    `self_scan?/1` predicate.
  - `test/giulia/storage/arcade/consolidator_prune_test.exs` — input
    contracts on retention pruning.
  - `test/giulia/persistence/writer_flush_now_test.exs` — flush_now
    contract.

870 tests / 10 properties / 0 failures across the touched subsystems
(`mcp/`, `knowledge/`, `context/`, `persistence/`, `storage/`,
`daemon/`).

### Migration

  - L2 caches auto-invalidate via `CodeDigest` envelope mechanism.
  - All MCP tool names / shapes unchanged. Clients calling
    `index_enrichment`, `intelligence_enrichments`,
    `knowledge_verify_l2`, `knowledge_verify_l3` via MCP for the first
    time may have been previously hitting the unknown-tool catch-all;
    they now succeed with the documented HTTP-equivalent shapes.
  - `POST /api/index/compact` callers without the `include` param see
    no change.
  - The `arcade_history_builds` config field is optional; missing it
    defaults to 10.

## [0.3.6 – Build 159] — 2026-04-27 — Multi-defimpl Phase 2: function fan-out across all sibling impls

`defimpl X, for: [T1, T2, T3]` previously emitted N module entries
(Phase 1, v0.3.0) but did not duplicate the protocol-impl function
set across each sibling — only the first sibling was attributed in
`function_info`. Phase 2 ensures each sibling impl module's function
set is fully populated for graph parity, so dependents queries
(`Knowledge.Store.dependents/2`, `find_unprotected_hubs/1`,
`pre_impact_check`) return identical results regardless of which
sibling is queried.

## [0.3.5 – Build 159] — 2026-04-27 — Topology rolls up Pass 7-11 edges; Graph Explorer isolates panel

`/api/knowledge/topology` previously used `all_dependencies/1` which
filters to module↔module edges only. Pass 7-11 (protocol_impl,
behaviour_impl, router_dispatch, mfa_ref, capture_ref, apply_ref,
use_import_ref) all emit module→function or function→function edges,
so module-level visualizations dropped them silently — defimpls of
project protocols, controller actions, MFA-tuple-dispatched modules,
and macro-injected import targets all rendered as isolated nodes even
though `dead_code` correctly counted them as live.

New `Giulia.Knowledge.Store.all_dependencies_with_rollup/1` walks
every edge in the graph and projects function endpoints to their
parent module via vertex labels. Self-loops introduced by intra-module
rollup (e.g., a defimpl whose body recurses into its own protocol via
its own helper) are dropped; function endpoints that don't map to any
project module are skipped. The topology endpoint switched to the
rollup variant.

`graph.html`: isolated nodes are pulled off the canvas into a
right-side sidebar split into "External boundaries" (complexity == 0:
GenServer, etc.) and "Truly isolated" categories so the main canvas
stays readable on large graphs.

## [0.3.4 – Build 159] — 2026-04-27 — Warm-restored projects bypass the not_indexed 409 gate

Projects warm-restored from L2 CubDB on daemon startup were
previously gated as `:not_indexed` by `Helpers.scan_state/1` despite
having a complete graph in L1 ETS — every scan-dependent endpoint
returned 409 Conflict until the user manually triggered a rescan. The
gate's intent was "block reads against an empty index," but it
predated `Persistence.WarmRestore` which populates a real graph
without going through `:scan_complete`.

`Giulia.Context.Indexer.register_warm_restored/2` is now invoked by
`WarmRestore` after restoring the L1 graph from L2. It registers the
project with `status: :idle`, `last_scan: nil`, `file_count: <known>`
so `scan_state/1` correctly classifies it as `:ready`. Scan-dependent
endpoints (`/api/knowledge/*`, `/api/index/complexity`, etc.) serve
warm-restored projects immediately on daemon restart.

## [0.3.3 – Build 159] — 2026-04-27 — Indexer post-scan pipeline non-blocking; new `:building` state

Reliability fix. `Indexer.handle_cast({:scan_complete, ...})` previously
ran the post-scan pipeline (`mix compile` + `Knowledge.Store.rebuild` +
`SemanticIndex.embed_project`) inside the GenServer process. While that
work ran (10-30+ seconds on a Phoenix app or on Giulia's self-scan),
the Indexer mailbox was blocked. Any `Indexer.status/1` `GenServer.call`
queued behind it and hit the default 5s timeout — caller crashed,
Plug router emitted 500, eventually docker healthcheck restarted the
container.

Surfaced specifically when scanning Giulia itself (170 files of meta-
AST work — heavier than typical project code; previous Plausible /
AlexClaw scans completed within 5s and never tripped the timeout).

### Fix

`handle_cast({:scan_complete, project_path}, ...)` now:
1. Computes `stats` (fast, in-process)
2. Sets the project state to `:building` (new status atom)
3. Spawns a `Task.Supervisor.start_child(Giulia.TaskSupervisor, ...)` running
   `run_post_scan_pipeline/1` — the heavy compile + rebuild + embed work
4. Returns `{:noreply, new_state}` immediately

The task casts back `{:scan_complete_done, project_path}` when the
pipeline finishes; that callback flips the status to `:idle`. Errors
inside `run_post_scan_pipeline/1` are caught with `rescue` and logged
but never crash the Indexer.

The status check helper (`Giulia.Daemon.Helpers.scan_state/1`) now
recognizes `:building` as a `:pending` state — knowledge endpoints
return 409 Conflict with a hint pointing at status polling, same UX
as `:scanning`.

### Verified

- Concurrent stress: 5 parallel `Indexer.status/1` polls during an
  active force-rescan of Giulia all return instantly with
  `{"status":"building","file_count":170}`. Previously these queued
  in the mailbox and timed out at 5s.
- Container survives the stress test (no docker restart).
- 1063 unit tests + 13 properties pass; 0 regressions.

### Type spec change

New atom `:building` added to `Giulia.Context.Indexer.scan_status` type
union. Consumers reading the status field via the typed API should
handle this state. The `scan_state/1` helper already does.



Patch release. Two fixes that together produce the cleanest dead-code
state across canonical codebases since the project began.

### Fixed — TestReferences alias resolution (roadmap item 2h)

`Giulia.Tools.TestReferences.referenced_functions/1` now resolves
`alias` directives before recording MFA strings. Previously, a test
using `alias AlexClawTest.Skills.EchoSkill` followed by
`EchoSkill.config_help()` recorded `"EchoSkill.config_help/0"` — a
short form the dead-code classifier's `:test_only` predicate could
never match against the real `"AlexClawTest.Skills.EchoSkill.config_help/0"`.
Mirror's the alias-resolution pattern from
`Giulia.Knowledge.Metrics.collect_all_calls/1` (single-segment +
multi-alias `alias Mod.{A, B}` + `alias Mod, as: Other`; Sourceror
keyword-key wrapping handled).

### Fixed — TemplateReferences scoped to project source roots

`Giulia.Tools.TemplateReferences.scan/1` now scopes its `*.heex` /
`*.eex` walk to the project's source roots (returned by
`Giulia.Context.ScanConfig.absolute_roots/1` — typically `lib/` plus
`test/support/` plus whatever `mix.exs` `elixirc_paths/1` adds).
Previously it walked everything under `project_path/**`, including
`deps/` (third-party templates from `phoenix_live_dashboard`,
`phoenix` codegen, etc.) and `_build/`, whose qualified function
references coincidentally over-exempted local modules.

### Empirical impact on canonical codebases

| Codebase | v0.3.1 dead | v0.3.2 dead | Notes |
|---|---|---|---|
| AlexClaw | 6 | **0** | All 6 `EchoSkill.*` test-only entries now correctly resolved |
| Plausible | 10 | **3** | 7 alias-blind entries resolved; remaining 3 = canonical residual (2 true positives + 1 SiteEncrypt accept-as-residual) |

This is the cleanest residual state we've measured. The 3 remaining
on Plausible are documented in the roadmap as known-and-accepted —
not bugs.



Patch release that completes the deferred slice-a from v0.3.0. The
`:template_pending` category was a placeholder for "we know this might
be template-callable but we never wrote the parser." Slice-a builds the
parser (`Giulia.Tools.TemplateReferences`), so template-referenced
functions are now exempted from the dead-code list at detection time
rather than reaching the classifier.

### Changed — observable analysis output

- **`/api/knowledge/dead_code` no longer emits `:template_pending`.**
  The category is removed from the type union. Functions called from
  `*.heex` / `*.eex` templates are exempted from the response entirely
  (matching Pass 7-11's exemption pattern). Consumers reading
  `summary.by_category` will see the field gone; if you were depending
  on its presence, switch to checking `Map.get(summary.by_category, :template_pending, 0)`.
- **Plausible empirical delta**: the 3 `PlausibleWeb.{EmailView,LayoutView,SiteView}.plausible_url/0`
  entries that v0.3.0 mis-classified as `:template_pending` are now
  correctly exempted (they're called as `{plausible_url()}` from
  `templates/layout/base_email.html.heex` etc., resolved through the
  conventional `templates/<view>/...` → `<App>Web.<View>View` mapping).

### Added — `Giulia.Tools.TemplateReferences`

New scanner that walks `*.heex` and `*.eex` files and extracts function
references in three syntactic surfaces:

- HEEx curly interpolation: `{Module.Sub.fn(args)}`
- Old EEx interpolation: `<%= Module.Sub.fn(args) %>` and `<% expr %>`
- HEEx component invocation: `<Module.Sub.fn args />` (qualified) and
  `<.local_fn args />` (local)

Returns `%{qualified: MapSet, local_per_file: %{path => MapSet}}`. The
local-per-file map is then resolved to a target module via Phoenix
path conventions:

1. Strip `.heex`/`.eex`/`.html` from the template path; if the resulting
   `.ex` sibling exists in the project's module index, use that module
   (LiveView / Component / colocated templates).
2. `lib/<app>_web/templates/<view>/<file>.html.heex` → `<App>Web.<View>View`
   (older Phoenix layout).

`Metrics.dead_code_with_asts/3` consumes both signals as additional
exemption sets alongside `protocol_impl_modules`, `router_actions`,
`reference_targets`, etc.

### Known limitation surfaced (not introduced) — TestReferences alias-blindness

The cold-rescan triggered by this slice exposed a pre-existing
limitation in `Giulia.Tools.TestReferences.referenced_functions/1`: it
collects qualified `Mod.fn/N` strings from `*_test.exs` but does not
resolve `alias` directives. A test using
`alias AlexClawTest.Skills.EchoSkill` then `EchoSkill.config_help()`
records `"EchoSkill.config_help/0"`, not the fully-qualified form, so
the classifier's `:test_only` predicate misses the match. Filed as
roadmap item 2h. Fix mirrors the resolve_alias pattern from
`metrics.ex` `collect_all_calls/1`.



The minor bump (v0.2.x → v0.3.0) is justified by new public API surface:
two new endpoints, additive fields on three existing endpoints, a new
plugin behaviour, and a new persistence keyspace. Everything is
backward-compatible — old consumers reading existing fields keep working.

### Added — dead-code categorization

`/api/knowledge/dead_code` entries now carry a `:category` field and the
response gains a `:summary` map. Categorization turns the irreducible
residual into honest signal: most entries on real codebases aren't bugs,
they're library public API, test-only entry points, or template-only
references blocked on the deferred `.heex` slice.

```
%{
  dead: [
    %{module, name, arity, type, file, line,
      category: :genuine | :test_only | :library_public_api |
                :template_pending | :uncategorized}
  ],
  count, total,
  summary: %{
    by_category: %{...counts...},
    irreducible: integer,   # test_only + library_public_api + template_pending
    actionable:  integer    # genuine + uncategorized
  }
}
```

Precedence: `:test_only` > `:library_public_api` > `:template_pending` >
`:genuine`. Empirical results on canonical codebases:

| Codebase | Dead | After categorization |
|---|---|---|
| AlexClaw | 1 | 1 genuine |
| Plug | 1 | 1 library_public_api |
| Bandit (post-Pass-10-ext) | 2 | 2 library_public_api |

Driven by reused infrastructure: `Giulia.Tools.TestReferences.referenced_functions/1`
(extends slice-E2's module-level walker to function-level), and a new
`Giulia.Context.ScanConfig.application_mod?/1` reading `mix.exs`
`application/0` for the library/app distinction.

### Added — external tool enrichment ingestion

Pluggable behaviour `Giulia.Enrichment.Source` plus a JSON-driven
registry (`priv/config/enrichment_sources.json`). **Two sources ship:
Credo and Dialyzer.** Adding Sobelow / ExDoc / Coverage is one parser
module + one JSON line.

**New endpoints:**

- `POST /api/index/enrichment` — ingest tool output. Body:
  `{tool, project, payload_path}`. The daemon dispatches to the
  registered source module via the registry, parses, and persists
  findings in a separate CubDB keyspace. Validates `payload_path`
  against an allowlist (`scan_defaults.json :enrichment_payload_roots`)
  to prevent the endpoint from becoming an arbitrary-file-read
  primitive. Returns `{tool, ingested, targets, replaced}`.

- `GET /api/intelligence/enrichments?path=X&mfa=Y` (or `&module=Y`) —
  uncapped drill-down for explicit per-vertex queries. Returns
  `{findings: %{tool => [findings]}, target}`. Distinguishes `%{}`
  (never ingested for project) from `%{credo: []}` (ingested, no
  findings on this target) via a sentinel marker — different signals
  for consumer agents.

**Two consumer endpoints surface findings inline:**

- `pre_impact_check` — `affected_callers[*].enrichments` carries per-
  caller findings so refactor decisions consider type warnings + style
  issues alongside blast radius.
- `dead_code` — entries gain `:enrichments` so type-warning + dead-code
  residual surface together.

Both apply caps (`priv/config/scoring.json :enrichments`): errors
uncapped, top-3 warnings per entry, drop info, per-response cap of 30
deduplicated by `{check, severity}`. Caps are defensive defaults —
on real codebases (Plausible: 98 Credo findings on 3867 functions)
they rarely fire. Capping logic is shared across consumers via
`Giulia.Enrichment.Consumer`.

**Replace-on-ingest semantics, decoupled lifecycle.**
`Giulia.Enrichment.Writer.replace_for/3` deletes prior findings for
`{tool, project}` and writes the new set inside `CubDB.transaction/2`
so concurrent reads never see half-deleted state. Enrichment keys
under `{:enrichment, tool, project, target}` are **preserved by
`Persistence.Writer.clear_project/1`** — tool ingest cadence (CI on
every PR) is decoupled from source rescan cadence (daemon scans on
its own schedule).

**Provenance per finding:** `tool_version`, `run_at`, per-file
`source_digest_at_run`. Consumers can compare against the current
file digest to flag stale findings on changed files.

**Severity is config-driven.** Each registered source carries a
`severity_map` in `enrichment_sources.json`. Credo: 5 entries
(`"warning" => "error"` covers Credo's misleadingly-named real-bug
category). Dialyzer: 47 entries covering dialyxir's full warning
catalogue. Tunable without recompile.

**Telemetry from day one:** `[:giulia, :enrichment, :ingest]`,
`[:giulia, :enrichment, :parse_error]`, `[:giulia, :enrichment, :read]`.

### Known limitation — function line-range precision

Per-function line ranges are derived as `next_function.line - 1`
after stable per-file sort. This loses precision against multi-clause
definitions, `defmacro` bodies with `quote do`, multi-arity
definitions interleaved with other functions, and `@doc` heredoc gaps.
Empirical impact: most Credo findings on Plausible currently resolve
to module-scope rather than function-scope. The three-path
arity-resolution waterfall in each parser surfaces this honestly via
`scope: :module` and a `:resolution_ambiguous` flag rather than
guessing wrong arity. Roadmap item 2g — capture true `:line_end`
during AST extraction — predicted to sharpen attribution.

### Also since v0.2.2 — what shipped incrementally to users

Listed compactly; see git log for full detail.

- **Dispatch-edge synthesis (Pass 7-11)** — protocol_impl, behaviour_impl,
  router_dispatch, mfa_ref / capture_ref / apply_ref / mfa_arg_ref,
  use_import_ref. Net effect across canonical codebases: −97 false-
  positive `dead_code` reports.
- **Reference-based test detection (slice E2)** — replaces filename-
  matching `has_test`; 38 modules correctly reclassified yellow→green
  on Plausible.
- **Config externalization** — `scoring.json`, `dispatch_patterns.json`,
  `scan_defaults.json`, `enrichment_sources.json`, all auto-invalidated
  via `CodeDigest` envelope (commit `b1efd08`).
- **MCP server (Build 155)** — 71 tools auto-generated from `@skill`
  annotations on sub-routers. Bearer-auth gated by `GIULIA_MCP_KEY`.
- **OTP cleanup tier 1 + 2** — supervised SSE inference, ContextManager
  `:exit` handling, state-recovery invariant, ETS heir, reconcile paths.
- **Correctness invariants** — `verify_l2`, `verify_l3` endpoints with
  stratified sample-identity checks; 15 mix-test drift detectors.
- **Filter-accountability tests** — 11 distinct silent-over-match bugs
  caught across `Indexer.ignored?`, `ToolSchema.mcp_compatible?`,
  `Conventions.check_try_rescue_flow_control`, `Topology.fuzzy_score`.
- **Force-rescan + path validation** — `?force=true` on
  `/api/index/scan`; 422 on missing/invalid paths or missing project
  marker.
- **Multi-type defimpl** — `defimpl X, for: [T1, T2, T3]` now extracts
  as N proper impl modules instead of `Unknown`.

### Migration

- L2 caches auto-invalidate via `CodeDigest`. First daemon restart on
  v0.3.0 rebuilds graph + metrics from existing ASTs (cheap; AST cache
  unaffected).
- All field additions are backward-compatible. Consumers reading
  existing keys (`dead`, `count`, `total`, `affected_callers`, etc.)
  continue to work without changes.

## [0.2.2 – Build 155+] — 2026-04-23 — Graph-completeness correctness fix

### Changed — observable analysis output (BREAKING for cached results)

**Three AST walkers had the same "first-module-wins" bug for files with
multiple top-level `defmodule` blocks, plus a parallel single-segment-
only alias-resolution bug. All three are now fixed.** The bug silently
under-counted static call edges on any codebase with (a) multiple
top-level `defmodule` declarations per file, or (b) aliased module
references spanning more than one segment (e.g. `alias Plausible.
Ingestion` + `Ingestion.Request.build(...)`).

- `Giulia.AST.Extraction.extract_modules/1` + `extract_functions/1`
  (commit `7792107`) — module-stack traversal via `Macro.traverse/4`;
  nested `defmodule` names fully qualified; `function_info` gains
  `:module` so sibling nested modules don't collapse by `{name, arity}`.
- `Giulia.Knowledge.Metrics.collect_all_calls/1` (commit `6da8764`) —
  same module-stack fix for the detector-side AST walk that feeds
  `dead_code`; `resolve_alias/2` for multi-segment alias references.
- `Giulia.Knowledge.Builder.add_function_call_edges/3` (commit
  `9d5cb1e`) — same fixes for the graph-side AST walk that produces
  the edges every analysis reads.

**Quantified impact on analytics-master** (Plausible Community Edition,
466 files in lib/):

| Measurement | Before (v7) | After (v8) | Δ |
|---|---|---|---|
| Graph edges | 5,670 | 6,000 | **+330 (+5.8%)** |
| Graph vertices | 3,886 | 3,891 | +5 |
| Graph components | 1,401 | 1,225 | **−176** |
| `dead_code` count | 103 | 37 | **−66** |

**Operationally significant:** The 176 components that merged indicate
the missing edges were **bridge edges connecting previously-isolated
small subgraphs to the main graph**. Headline findings (top
`change_risk` rankings, heatmap red zones, 234-module SCC size,
`fan_in_out` top-6) are UNCHANGED on analytics-master — the bug
shape was specifically in peripheral-to-core edges, not hub-to-hub.
However:

- **`pre_impact_check` results for modules with aliased call patterns
  were under-counted.** If anyone used pre_impact_check in an
  automated refactor-safety loop on such modules before this fix,
  those decisions were made on incomplete data.
- **Tail rankings in `change_risk`, `coupling`, `unprotected_hubs`,
  `fan_in_out` shifted.** Low-rank entries may have reordered; at
  least one top-8 coupling pair changed in the analytics-master
  data (`Plausible.Teams → Repo` dropped out of top 8, replaced by
  `Plausible.Teams → Plausible.Teams.Team`).
- **`dead_code` produced ~2-3× the correct number of false
  positives** on projects with multi-defmodule-per-file patterns.
  Reports that listed dead functions in modules with many
  top-level defmodules in one file (e.g. `Plausible.HTTPClient`)
  should be regenerated.

### Changed — schema_version

`Giulia.Persistence.Store.@schema_version` bumped from **7 to 8**.
CubDB caches from v7 are known-incomplete and will be invalidated on
next daemon load; projects will cold-rescan. AST-entry key shapes are
unchanged, but graph binaries are — so the version bump forces a
fresh graph build from the corrected extractor pass.

**Anyone running Giulia in automation or CI:** expect the first scan
after upgrading to take the normal cold-start duration (proportional
to `file_count`) rather than the usual warm-restore millisecond path.

### Added — index-time edge synthesis for runtime dispatch

`Giulia.AST.Extraction.module_node_info/1`'s `defimpl` clause captures
the protocol name as `module_info.impl_for`, and
`Builder.add_protocol_dispatch_edges/2` (Pass 7) synthesizes
`{:calls, :protocol_impl}` edges from the protocol module to each
function in each impl module. Makes `defimpl`-dispatched functions
reachable in graph traversal for every downstream analysis without
per-detector filter logic.

See `docs/feedback_dispatch_edge_synthesis.md` in the project's
`.claude/` memory for the architectural commitment this implements:
runtime-dispatch semantics live in the indexer, not in detectors.
Next slices to land: `@behaviour`, Phoenix router, Ecto custom types,
Mix tasks (each a separate, measurable step with predicted vs actual
`dead_code` drop on analytics-master).

### Added — path validation at scan/init endpoints

`POST /api/init` and `POST /api/index/scan` now return 422 for missing
paths, non-directory paths, or directories without a project marker
(`mix.exs`, `GIULIA.md`, `package.json`, `Cargo.toml`, `go.mod`). Prior
behavior silently returned 200 "scanning" and the indexer then
refused the cast out-of-band — a caller couldn't tell the difference
between "scan in progress" and "scan silently rejected." (commit
`f9c4863`.)

### Added — startup warm-restore from L2

New `Giulia.Persistence.WarmRestore` GenServer walks `/projects/*` (and
`GIULIA_PROJECTS_PATH` if set) on boot and restores the L1 ETS graph
+ metrics from CubDB for every project with a valid schema_version
match. Fixes the empty-dropdown-after-restart bug and makes
`GET /api/projects` correct immediately after `docker compose restart`
without a rescan. (commit `e8c3fa3`.)
