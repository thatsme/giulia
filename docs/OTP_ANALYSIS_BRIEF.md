# Implementation Brief — OTP Deep Analysis

> **Audience**: the Claude Code session implementing this feature in the Giulia repo.
> **Companion doc**: `docs/OTP_ANALYSIS_SPEC.md` — the design spec (check catalog, detection rules, data model). Read it first. This brief is the *how*: integration points, ground rules, phase plan, acceptance criteria, and the final self-scan validation.
> **End state**: Giulia extracts her own supervision tree, runs all OTP checks against herself, and the findings become the committed residual baseline.

---

## Ground Rules (non-negotiable, from the project's own docs)

1. **Tests run in Docker only.** `docker compose -f docker-compose.test.yml run --rm giulia-test [file]`. Never bare `mix test` on the host (EXLA won't compile on Windows), never from `/app` (frozen snapshot).
2. **Baseline before, compare after.** `git stash` → full suite → record failure count per module → `git stash pop` → implement → full suite → identical failure profile + your new tests green. Never claim a failure is "pre-existing" without the before/after proof.
3. **Never run `mix format` on the full project inside the container** (CRLF corruption). Format only the files you touched, on the host.
4. **Every new config file goes into `CodeDigest.@tier_config_files` in the same commit that creates it.** `dispatch_invariants.json` and `relevance.json` are currently missing from the digest — do not add a third omission. (Add `dispatch_invariants.json` to the digest while you're in that file; it's a confirmed gap.)
5. **Universal defaults.** Shipped thresholds in `otp_checks.json` must produce sane output on Giulia, Plug, Bandit, and Plausible with zero tuning. A default that's wrong somewhere is release-gating, not "user can override."
6. **New endpoints follow the Edge → Facade → Store layering** (`Daemon.Edge.resolve_ready/1` → `Knowledge.Facade` → `Knowledge.Store`). REST route body and MCP dispatch handler are thin renderers over the same facade call. Extend `test/giulia/mcp/rest_mcp_parity_test.exs` for every new facade-routed endpoint.
7. **`@skill` annotations on every new route** — Discovery API and MCP ToolSchema generate from them; a route without `@skill` is invisible to both.
8. **Elixir conventions per `CODING_CONVENTIONS.md`**: tagged tuples, pattern-match heads, no runtime atoms, `@spec` + `@moduledoc` on everything public.

## Integration Map (where things live)

| Concern | File(s) |
|---|---|
| Builder passes (add Pass 12 here) | `lib/giulia/knowledge/builder.ex` (pass pipeline; each pass = pure fn graph → graph) |
| Cycle detection / traversal to reuse | `lib/giulia/knowledge/topology.ex` |
| Behaviour-implementer detection (find GenServers) | `lib/giulia/knowledge/behaviours.ex` + behaviour_impl edges from Pass 8 |
| Function bodies / call-site walking to reuse | Pass 4 machinery in `builder.ex`; AST access via `lib/giulia/context/store.ex` |
| New analyzer module | create `lib/giulia/knowledge/otp.ex` (+ `lib/giulia/knowledge/otp/` if it grows) |
| Conventions engine (info-tier heuristics: `infinity_call_timeout`, `one_for_all_amplification`, `unlinked_start`) | `lib/giulia/knowledge/conventions.ex` (Tier 2 rule family `otp_deep`) |
| Config loader (new) | create `lib/giulia/config/otp_checks.ex`, mirror `lib/giulia/config/relevance.ex` pattern (`:persistent_term`, fail-loud) |
| Config file (new) | `priv/config/otp_checks.json` — schema in spec §5 |
| Digest registration | `lib/giulia/knowledge/code_digest.ex` → `@tier_config_files` (+ add the missing `config/dispatch_invariants.json`) |
| Routes | `lib/giulia/daemon/routers/knowledge.ex` (`GET /supervision`, `GET /otp_risks`) |
| Facade | `lib/giulia/knowledge/facade.ex` (coercion, defaults, `schema_version` stamp) |
| MCP dispatch | `lib/giulia/mcp/dispatch/knowledge.ex` |
| Metric caching + `{:graph_ready}` hooks | `lib/giulia/knowledge/store.ex` (cache `otp_risks` alongside heatmap/dead_code; warm eagerly post-rebuild) |
| Runtime fusion (Phase 4) | `lib/giulia/runtime/ingest_store.ex` (snapshot join), `lib/giulia/runtime/collector.ex` (message_queue_len source) |
| Graph Explorer view | monitor router static HTML — `lib/giulia/daemon/routers/monitor.ex` + its embedded/priv HTML |

## Phase Plan

Execute in order; each phase is independently shippable and ends with the full suite green.

### Phase 1 — Supervision topology (Pass 12) + `/api/knowledge/supervision`

1. Pass 12 in `builder.ex`: parse `Application.start/2` child lists and `Supervisor.init/1` / `Supervisor.start_link/2` specs. Handle: bare module, `{module, args}`, spec maps, `Supervisor.child_spec/2`. Emit `{:supervises, %{restart, order, strategy, conditional}}` edges (spec §2).
2. Conditional children: child lists built through `if`/`case`/list concat must yield the **union** with `conditional: true` — Giulia's own `application.ex` (tiered children on `GIULIA_ROLE`) is the acceptance fixture for this.
3. `DynamicSupervisor` → vertex flagged `dynamic: true`, no child edges.
4. Endpoint + facade + MCP tool + parity test entry.
5. Golden fixtures: `test/fixtures/extraction/` gains supervision shapes (flat, nested, conditional, dynamic, child_spec override) with frozen `.expected.exs`, regenerable via `GOLDEN_UPDATE=1`.

**Acceptance**: self-scan returns Giulia's tree — root supervisor, 5 tiers, `conditional: true` on TIER 2/3/5 children, `Bandit` absent under `MIX_ENV=test`. Graph edge counts unchanged for all pre-existing labels (Pass 12 adds, never mutates).

### Phase 2 — `blocking_init` + `missing_catch_all_handle_info`

1. `Knowledge.Otp.blocking_init/2`: walk `init/1` + intra-module private-helper closure; match MFAs against `otp_checks.json` lists (error/warning tiers per spec §3.1). Note `handle_continue` presence in the finding.
2. `Knowledge.Otp.missing_catch_all_handle_info/1`: fires only when ≥1 `handle_info/2` clause exists and none has an unguarded catch-all head (spec §3.5 — the `use GenServer` default-override semantics are the whole point; get them right).
3. Findings shape mirrors conventions output (`by_severity`, `by_category`, `suppressions_applied`); `?suppress=` works.
4. **Filter-accountability tests for every predicate**: drop-side fixtures parametric over the criteria AND strictly-larger pass-through sets. This is the house pattern; it exists because it caught 11 over-match bugs.

**Acceptance**: deliberate-bug fixtures flagged; clean fixtures pass; Giulia self-scan findings reviewed and recorded (do not tune thresholds to zero — record honest findings).

### Phase 3 — Synchronous call-subgraph checks

1. Build the sync inter-process subgraph: edges originating in `handle_call/3` / `handle_cast/2` / `handle_continue/2` bodies (+ intra-module closure), targeting `GenServer.call`/`multi_call` on other implementer modules.
2. `cross_process_call_cycle`: SCC via existing `Topology`; confidence `high` when both endpoints are `name: __MODULE__` singletons, else `medium` (spec §3.2).
3. `sync_call_chain_depth`: depth ≥ `otp_checks.json` threshold; finding carries the full chain + per-hop timeout + summed budget.
4. `singleton_bottleneck` (static half): registered-name servers with sync fan-in ≥ threshold.
5. Test fixture: two toy GenServers deadlocking each other in `handle_call` — asserted `high`-confidence cycle. This fixture is the feature's reason to exist; freeze it.

**Acceptance**: `GET /api/knowledge/otp_risks?path=P&check=...` filters work; cycle findings rank P0 shape; parity test extended; full suite green.

### Phase 4 — Runtime fusion for `singleton_bottleneck`

1. Join static suspects to Collector snapshots by registered name: max `message_queue_len` + reduction share in the last burst window (via `IngestStore`).
2. Escalate warning → error when queue threshold exceeded; response carries `runtime: %{confirmed, max_queue_len, window}` or `runtime: :unavailable`.
3. Degrade gracefully: no snapshots (monitor absent) → static findings unchanged, `runtime: :unavailable` — same pattern as EmbeddingServing absence.

**Acceptance**: with monitor running, self-scan under induced load (fire N concurrent `/api/knowledge/stats` requests) shows queue data attached to `Knowledge.Store` suspect.

### Phase 5 — Polish

1. Info-tier `otp_deep` rules into the conventions engine (spec §3.6).
2. Graph Explorer "Supervision" view mode.
3. Docs: ARCHITECTURE.md (Pass 12 in the pass table, new §18 blind-spot rows per spec §2), API.md (two endpoints), CONFIGURATION.md (`otp_checks.json` reference), REPORT_RULES.md ("Process Architecture" section; deadlock cycles join the P0 tier in Section 16).
4. Update endpoint/tool counts everywhere they're stated (API.md quick-ref, INSTALLATION.md, ROADMAP.md) — count drift is a known disease in this repo; don't feed it.

## Final Validation — Giulia vs. Giulia

1. Full rebuild, `docker compose up -d`, force scan of the Giulia project itself.
2. `GET /api/knowledge/supervision` — tree matches `application.ex` by hand-inspection.
3. `GET /api/knowledge/otp_risks` — capture full output.
4. Expected-findings review (verify, don't assume): `Knowledge.Store` and `Context.Store` are the singleton-bottleneck candidates (high fan-in by design — `Store.Reader` exists precisely to bypass the GenServer for bulk reads; if flagged, that's a *correct* finding with a documented mitigation, record it as such). `Persistence.WarmRestore` should be **clean** on blocking_init (it deliberately defers I/O via `send/2` self-message — if flagged, the check is wrong, fix the check).
5. Run against Plug, Bandit, and (if cloned) Plausible; record all residuals in a new "OTP residual baseline" table in the spec — the analogue of the dead-code canonical-residuals table.
6. Commit baselines. Any future change that moves these numbers gets the slice-skeptical treatment per GIULIA.md.

## Definition of Done

- [ ] All phases merged, full suite green with baseline-identical failure profile
- [ ] Golden fixtures + deadlock fixture + filter-accountability tests in place
- [ ] REST/MCP parity test covers both new endpoints
- [ ] `otp_checks.json` in CodeDigest (and `dispatch_invariants.json` gap closed)
- [ ] Docs updated, counts consistent
- [ ] Self-scan + Plug/Bandit baselines committed to the spec
