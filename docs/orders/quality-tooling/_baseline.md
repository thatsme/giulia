# Quality Tooling — Pre-flight Baseline

Captured: 2026-05-21 | Order: `docs/orders/2026-05-21-quality-tooling.md`
Updated after toolchain pinning + ArcadeDB startup.

## Working tree clean
**No** — untracked files, none are code:
- `TODO.md`
- `docs/orders/2026-05-21-quality-tooling.md` (the order itself)
- `docs/orders/2026-05-21-quality-tooling_tmp.html` (export artifact of the order)
- `docs/orders/quality-tooling/` (this report dir + logs)

Benign — the order's commits stage explicit file lists.

## Current branch
`main`

## Toolchain — exact versions (from inside `giulia-worker`)
```
Erlang/OTP 27 [erts-15.2.7.8]   →  OTP 27.3.4.11
Elixir 1.19.5 (compiled with Erlang/OTP 27)
```

### PROPOSED — not yet written (awaiting your confirmation)

**`.tool-versions`** (new file, repo root):
```
erlang 27.3.4.11
elixir 1.19.5-otp-27
```

**`mix.exs`** — line 19, change the `elixir:` constraint:
```diff
-      elixir: "~> 1.17",
+      elixir: "~> 1.19",
```
`~> 1.19` covers 1.19.x and forward to <2.0, matching the installed 1.19.5.
The order's Phase 3 CI template pins `1.17.0` / OTP `27.0` — those will be
corrected to `1.19.5` / `27.3.4.11` when Phase 3 is reached.

> These two changes are described, not applied — per "stage the changes
> mentally and report. Do not proceed until I confirm the version pin."

## ArcadeDB — started
Command run:
```
docker run -d --name arcadedb -p 2480:2480 -p 2424:2424 \
  -e JAVA_OPTS="-Darcadedb.server.rootPassword=playwithdata" \
  arcadedata/arcadedb:latest
```
- Root password `playwithdata` — matches `config/config.exs:40`
  (`arcadedb_password: System.get_env("ARCADEDB_PASSWORD", "playwithdata")`).
- `config/test.exs` is empty; no test-specific Arcade override exists, so the
  `config.exs` defaults (`user: root`, `db: giulia`, password as above) apply.
- Verified ready: `GET /api/v1/ready` → `HTTP 204` from the host, and from
  inside `giulia-worker` via `http://host.docker.internal:2480` → `HTTP 204`.
  (Worker's `ARCADEDB_URL` env is `http://host.docker.internal:2480`.)
- ArcadeDB is intentionally **not** in `docker-compose.yml` (line 169:
  "Start it separately") — it must be running for the Arcade test suites.

### ArcadeDB version `:latest` resolved to (captured 2026-05-21)
- **Server version:** `26.6.1-SNAPSHOT` (build `139c9f7dabfbf64399d35e350c07a1aa394936ea`,
  build timestamp `1779309696053`), reported by `GET /api/v1/server`.
- **Image digest:** `arcadedata/arcadedb@sha256:1213c071ef0d324bb256facf0575e4f0606eac57d55d62d40a46c792cd33eced`
- **Note:** `:latest` currently points at a `-SNAPSHOT` build, not a stable
  release. Snapshot tags are mutable — they get overwritten by later CI builds —
  so `:latest` is not a reproducible pin.

### Spot-check — 5 previously-failing ArcadeDB tests, `mix test --trace`
Run after ArcadeDB came up, to confirm the tests genuinely pass (not "connects
now but fails differently"). All 5 passed with real assertion timings:

| Test | Result |
|------|--------|
| `client_test.exs:113` — upsert_module/4 defaults metrics to zero | pass (2.9ms) |
| `client_test.exs:292` — complexity_history/2 returns empty for unknown project | pass (1.3ms) |
| `indexer_test.exs:17` — snapshot/2 succeeds with empty graph for unknown project | pass (50.9ms) |
| `indexer_test.exs:43` — snapshot/2 adversarial handles zero build_id | pass (46.9ms) |
| `verifier_test.exs:96` — verify/2 happy path faithful L1→L3 round-trip | pass (74.6ms) |

`5 tests, 0 failures`. The ArcadeDB failures were genuinely connectivity-only.

### BLOCKER — validated version `26.4.1` does not exist as a Docker tag
`MEMORY.md` records "ArcadeDB v26.4.1" as the validated version (Build 136).
The order's step 3 says to restart on `arcadedata/arcadedb:26.4.1` *after
verifying the tag exists on Docker Hub*. **It does not exist.**

Docker Hub `arcadedata/arcadedb` tags (most recent first) — `26.4.1` is absent:
```
26.6.1-SNAPSHOT   latest   26.5.1   26.5.1-SNAPSHOT   26.4.2
26.4.1-SNAPSHOT   26.3.2   26.3.2-SNAPSHOT   26.3.1 ...
```
- `docker manifest inspect arcadedata/arcadedb:26.4.1` → tag missing.
- The only `26.4.1` form published is `26.4.1-SNAPSHOT` (mutable, not a pin).
- Nearest **stable** tags: `26.4.2` (next patch up from the memory value),
  `26.5.1` (newer stable).

Per the order — "Do not silently adopt either version as the new contract.
Surface the discrepancy and let me decide." — the version-pin step was halted
and surfaced. **User selected `26.4.2`** (closest stable release).

### Re-baseline on ArcadeDB 26.4.2
ArcadeDB restarted: `:latest` container stopped + removed, recreated on
`arcadedata/arcadedb:26.4.2` (digest `sha256:34009c7a3589…`, server reports
`26.4.2` — stable, no `-SNAPSHOT`). Ready `HTTP 204`, worker reaches it.

Full `mix test` re-run (`_baseline_test_arcade_2642.log`):
`13 properties, 2208 tests, 9 failures`, 99.6s.

**Bucket comparison — `:latest` (26.6.1-SNAPSHOT) vs `26.4.2`:**

| Failure bucket | :latest | 26.4.2 | Version-attributable? |
|----------------|--------:|-------:|-----------------------|
| Arcade suites (Client/Indexer/Verifier) | 0 | 0 | identical |
| `GoldenFixturesTest` (same 8 fixtures) | 8 | 8 | identical |
| `ApiAdversarialTest` — indexer-warmup timeout | 2 | 1 | no — flaky timing |
| **Total** | **10** | **9** | |

The raw count differs by **1** (10 vs 9). That single difference is the
known-flaky `ApiAdversarialTest` indexer-warmup timeout: the 26.4.2 run's one
failure carries the **identical** signature —
`GenServer.call(Giulia.Context.Indexer, {:status, ...}, 5000)` timeout in
`ready?/1` setup (`api_adversarial_test.exs:269`). One of the two flaky tests
simply happened to pass this run. It is not ArcadeDB-related.

The **version-attributable** buckets are identical: Arcade suites 0/0, golden
fixtures 8/8 (same fixture names). No behaviour change is attributable to the
ArcadeDB version. The 1-test delta is non-determinism in an unrelated test.

### Re-baseline on ArcadeDB 26.5.1 — GitHub's latest stable (May 11, 2026)
User noted via the ArcadeData GitHub releases page that `26.5.1` is the current
latest stable (26.4.2 is one release behind). ArcadeDB restarted on
`arcadedata/arcadedb:26.5.1` (digest `sha256:3d8183bceb93…`, server reports
`26.5.1` stable). Ready `HTTP 204`, worker reaches it.

Full `mix test` re-run (`_baseline_test_arcade_2651.log`):
`13 properties, 2208 tests, 14 failures`, 102.1s.

**Three-version bucket comparison:**

| Failure bucket | :latest 26.6.1-SNAP | 26.4.2 | 26.5.1 |
|----------------|--------------------:|-------:|-------:|
| `GoldenFixturesTest` (same 8 fixtures) | 8 | 8 | 8 |
| `ApiAdversarialTest` — indexer-warmup timeout (flaky) | 2 | 1 | 3 |
| **Arcade `VerifierTest`** | **0** | **0** | **3** |
| **Total** | **10** | **9** | **14** |

### STOP — 26.5.1 baseline DIFFERS (version-attributable regression)

26.5.1 introduces **3 `Giulia.Storage.Arcade.VerifierTest` failures** that do
not occur on either 26.4.2 or 26.6.1-SNAPSHOT. This is not flakiness — it is a
deterministic, ArcadeDB-version-attributable behaviour change:

- `verifier_test.exs:96` — happy-path L1→L3 round-trip: expected `overall:
  :pass`, got `:fail`; `count_parity: %{status: :l3_under_l1, l1: 2, l3: 1}` —
  an L1 call edge never reached L3.
- `verifier_test.exs:134` — drift detection: `count_parity.l3` expected 2, got 0.
- `verifier_test.exs:153` — drift detection: status expected `:l3_exceeds_l1`,
  got `:l3_under_l1`.

**Mechanism:** on 26.5.1 the Arcade write path errors on function-vertex and
function-call-edge inserts. The VerifierTest's small synthetic snapshots log
`functions: %{error: 3, ok: 0}` and `function_call_edges: %{error: 1, ok: 1}`
— writes that succeed cleanly on the other two versions. With function vertices
missing, the call edges that reference them cannot be created, so L3 ends up
with fewer edges than L1 and every Verifier parity/drift assertion fails.
(The Indexer tallies `error` counts but does not log each ArcadeDB response, so
the exact server-side rejection reason is not in the test log — root-causing it
would need a direct single-upsert probe against 26.5.1.)

**Non-monotonic — important:** the *newer* `:latest` (26.6.1-SNAPSHOT) and the
*older* 26.4.2 both pass all Arcade suites; only 26.5.1 (in between) fails. So
26.5.1 carries a regression that the 26.6.1 snapshot line appears to have
already fixed. (Note: even 26.4.2 shows `function_call_edges: error 87–97` out
of ~1890 on the *full-project* background snapshot — partial, load-dependent,
and not enough to fail any test; 26.5.1's errors are an order of magnitude
worse and reach function *vertices*, which 26.4.2 never does.)

Per the order — "If the baseline differs: stop. Report the delta. Do not
silently adopt either version as the new contract. Surface the discrepancy and
let me decide." — **the version-pin step is halted.** No docs pin, no
`docker-compose.yml` edit, no `_baseline.md` "proceed" was written.

### Candidate pin versions — summary for the decision

| Tag | Stable? | Arcade suites | Reproducible pin? |
|-----|---------|---------------|-------------------|
| `26.4.2` | yes (Apr 24 2026) | clean (0 failures) | yes — immutable |
| `26.5.1` | yes (May 11 2026, GitHub latest) | **3 VerifierTest failures** | yes — immutable |
| `26.6.1-SNAPSHOT` (`:latest`) | no — snapshot | clean (0 failures) | no — mutable tag |

### RESOLVED — ArcadeDB pinned to `26.4.2`

**Decision (user):** pin ArcadeDB to `arcadedata/arcadedb:26.4.2` — the most
recent *stable, immutable* tag whose Arcade test suites pass clean. `26.5.1`
(GitHub's latest stable) is rejected: it regresses the OpenCypher write path and
fails 3 `VerifierTest` tests. `:latest`/`26.6.1-SNAPSHOT` is rejected as a pin
because snapshot tags are mutable.

**Actions taken:**
- ArcadeDB container reverted to `arcadedata/arcadedb:26.4.2`
  (server reports `26.4.2`, `GET /api/v1/ready` → `HTTP 204`).
- `docker-compose.yml` (the comment block at the former line 169) updated with
  the explicit pinned `docker run` command and a note recording *why* 26.4.2 is
  pinned over the newer 26.5.1.

**Final pinned versions for this work stream:**

| Component | Pinned to |
|-----------|-----------|
| Erlang/OTP | `27.3.4.11` |
| Elixir | `1.19.5` (mix.exs `~> 1.19`) |
| ArcadeDB | `arcadedata/arcadedb:26.4.2` |

> The `.tool-versions` file and the `mix.exs` `elixir:` constraint change remain
> **proposed, not yet written** — still awaiting confirmation (see the
> "Toolchain" section above). Only the `docker-compose.yml` ArcadeDB comment has
> been written so far.

### Baseline accepted for Phase 1 (on ArcadeDB 26.4.2)
`13 properties, 2208 tests, 9 failures` — 8 `GoldenFixturesTest` (Elixir 1.19
AST-metadata drift, reproducible) + 1 `ApiAdversarialTest` (flaky indexer-warmup
timeout, 1–2 per run). No ArcadeDB-suite failures. `mix compile
--warnings-as-errors` fails on 4 pre-existing warnings (detailed above).

## `mix compile --warnings-as-errors`
**FAIL** — 4 warnings. Plain `mix compile` (no `--warnings-as-errors`) succeeds.
Full log: `_baseline_compile.log`. All 4 detailed below.

## `mix test`

| Run | Tests | Failures | ArcadeDB |
|-----|-------|----------|----------|
| Initial (`_baseline_test.log`) | 2208 | **50** | down |
| After ArcadeDB up (`_baseline_test_arcade.log`) | 2208 | **10** | up |

Re-baseline failures (10), exactly as predicted:

| Module | Failures | Cause |
|--------|----------|-------|
| `Giulia.AST.GoldenFixturesTest` | 8 | Golden fixture drift — AST extraction output differs from stored fixtures (Elixir 1.19 changed AST node metadata; fixtures predate it) |
| `Giulia.Integration.ApiAdversarialTest` | 2 | `GenServer.call(Giulia.Context.Indexer, ...)` 5s timeout in setup — indexer still warming |

- 40 ArcadeDB `:econnrefused` failures **cleared** by starting ArcadeDB.
- 8 golden-fixture failures **remain** (toolchain drift, reproducible).
- 2 indexer-timeout failures **still failed** this run (timing-dependent — they
  may pass on a run where the indexer has finished warming).

## Source file count
321 total — `lib/` 180, `test/` 141.

---

## The 4 compile warnings

> Analysis only. **No fix applied.** Each diff below awaits individual approval.

### Warning 1 — duplicate `@doc`, `lib/giulia/daemon/helpers.ex:147`

**Compiler text:**
```
warning: redefining @doc attribute previously set at line 132
 147 │   @doc """
     └─ lib/giulia/daemon/helpers.ex:147: Giulia.Daemon.Helpers (module)
```

**What triggers it:** Two `@doc` blocks sit back-to-back — line 132 and line
147 — before the next `def`. Elixir attaches a module attribute to the *next*
function definition; when two `@doc`s precede the same `def`, the second
overrides the first and the compiler warns. The line 132 doc describes
`require_scan_ready/2` (its body literally shows `with {:ok, conn} <-
require_scan_ready(conn, resolved_path)`), while the line 147 doc describes
`resolve_and_check_ready/1` (the function at line 169). Meanwhile the actual
`require_scan_ready/2` at line 184 has a `@spec` (line 182) but **no `@doc`**.
The line 132 docstring was simply placed against the wrong function.

**Proposed fix** — move the misplaced `@doc` block down to its real function.
Delete lines 132–146:
```diff
-  @doc """
-  Scan-state gate for a Plug handler. If the project is ready, returns
-  `{:ok, conn}`. Otherwise returns `{:halt, conn}` with a `409 Conflict`
-  already written to `conn` including the failure reason, the path that
-  was checked, and a hint pointing the caller at the next action.
-
-  Use via `with`:
-
-      with {:ok, conn} <- require_scan_ready(conn, resolved_path) do
-        # ... handler logic that assumes indexed data ...
-      end
-
-  The halt branch returns the already-responded conn so the caller can
-  just fall through.
-  """
   @doc """
   Combined gate used by most scan-dependent read handlers. Resolves
```
…and re-insert it immediately before `@spec require_scan_ready` (line 182):
```diff
+  @doc """
+  Scan-state gate for a Plug handler. If the project is ready, returns
+  `{:ok, conn}`. Otherwise returns `{:halt, conn}` with a `409 Conflict`
+  already written to `conn` including the failure reason, the path that
+  was checked, and a hint pointing the caller at the next action.
+
+  Use via `with`:
+
+      with {:ok, conn} <- require_scan_ready(conn, resolved_path) do
+        # ... handler logic that assumes indexed data ...
+      end
+
+  The halt branch returns the already-responded conn so the caller can
+  just fall through.
+  """
   @spec require_scan_ready(Plug.Conn.t(), String.t() | nil) ::
           {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
   def require_scan_ready(conn, project_path) do
```
Pure documentation move — no behaviour change.

### Warning 2 — dead clause, `lib/giulia/mcp/dispatch/approval.ex:22`

**Compiler text:**
```
warning: the following clause will never match:
    {:error, :not_found}
because it attempts to match on the result of:
    Giulia.Inference.Approval.respond(approval_id, approved)
which has type:
    dynamic(:ok)
 22 │         {:error, :not_found} ->
     └─ lib/giulia/mcp/dispatch/approval.ex:22: Giulia.MCP.Dispatch.Approval.respond/1
```

**What triggers it:** `Giulia.Inference.Approval.respond/2` (approval.ex:81–84)
is `@spec respond(String.t(), boolean()) :: :ok` and its body is a single
`GenServer.cast/2`, which always returns `:ok`. It can never return
`{:error, :not_found}`, so that clause in the MCP handler is unreachable.

**Proposed fix** — drop the dead clause; the `case` collapses to a straight
call:
```diff
       approved = args["approved"] == true or args["approved"] == "true"

-      case Approval.respond(approval_id, approved) do
-        :ok ->
-          {:ok, %{status: "responded", approval_id: approval_id, approved: approved}}
-
-        {:error, :not_found} ->
-          {:error, "Approval request not found: #{approval_id}"}
-      end
+      Approval.respond(approval_id, approved)
+      {:ok, %{status: "responded", approval_id: approval_id, approved: approved}}
     end
```
**Behaviour note:** `Approval.respond/2` is a `cast` — fire-and-forget — so the
MCP `approval_respond` tool already cannot detect an unknown `approval_id`; it
reports success regardless. The dead clause gave a false impression that it
could. This fix makes the code honest about an existing limitation; it does
not introduce one. If genuine not-found feedback is wanted, that is a separate
change to `Approval` (make `respond` a `call`) — out of scope here.

### Warning 3 — dead clause, `lib/giulia/mcp/dispatch/intelligence.ex:26`

**Compiler text:**
```
warning: the following clause will never match:
    {:error, reason}
because it attempts to match on the result of:
    Giulia.Intelligence.SurgicalBriefing.build(path, concept)
which has type:
    dynamic(:skip or {:ok, binary()})
 26 │           {:error, reason} -> {:error, inspect(reason)}
     └─ lib/giulia/mcp/dispatch/intelligence.ex:26
```

**What triggers it:** `SurgicalBriefing.build/2` is
`@spec build(String.t(), String.t()) :: {:ok, String.t()} | :skip` — every
path in its body (including the `rescue`) returns `{:ok, briefing}` or `:skip`,
never `{:error, _}`. So the `{:error, reason}` clause is dead. **Worse:** the
`case` has no `:skip` clause at all, so when `build` returns `:skip` (semantic
search unavailable, below relevance threshold, or an internal rescue) this
`case` raises `CaseClauseError` — the MCP `briefing` tool crashes.

**Proposed fix** — replace the dead `{:error, _}` clause with a `:skip` clause:
```diff
       if concept do
         case SurgicalBriefing.build(path, concept) do
           {:ok, result} -> {:ok, result}
-          {:error, reason} -> {:error, inspect(reason)}
+          :skip -> {:error, "Briefing unavailable: semantic search disabled or no relevant results"}
         end
       else
```
This silences the warning **and** removes the latent `CaseClauseError`.

### Warning 4 — dead clause, `lib/giulia/mcp/dispatch/intelligence.ex:67`

**Compiler text:**
```
warning: the following clause will never match:
    {:error, reason}
because it attempts to match on the result of:
    Giulia.Intelligence.PlanValidator.validate(path, plan)
which has type:
    dynamic({:ok, %{checks:..., modules_touched:..., recommendations:...,
            risk_score:..., verdict: binary()}})
 67 │         {:error, reason} -> {:error, inspect(reason)}
     └─ lib/giulia/mcp/dispatch/intelligence.ex:67
```

**What triggers it:** `PlanValidator.validate/3` is
`@spec validate(map(), String.t(), keyword()) :: {:ok, map()}` — the happy path
and the `rescue` path both return `{:ok, map()}` (the rescue returns
`{:ok, %{verdict: "error", ...}}`). It never returns `{:error, _}`, so the
clause is dead.

**Proposed fix** — `validate` always returns `{:ok, map()}`, which already
satisfies `plan_validate/1`'s `@spec` (`{:ok, term()} | {:error, String.t()}`),
so the `case` is pure ceremony:
```diff
       path = PathMapper.resolve_path(args["path"])

-      case PlanValidator.validate(path, plan) do
-        {:ok, result} -> {:ok, result}
-        {:error, reason} -> {:error, inspect(reason)}
-      end
+      PlanValidator.validate(path, plan)
     end
```

---

## Additional bugs found while analyzing the warnings (NOT compiler warnings)

> Reported per scope-discipline ("report it — don't fix it"). These are real
> defects adjacent to Warnings 3 & 4. They are **not** the compile warnings and
> are **not** covered by the proposed diffs above. They need a separate decision.

### Bug A — swapped arguments in `MCP.Dispatch.Intelligence.briefing/1`

`SurgicalBriefing.build/2` is defined `build(prompt, project_path)`. The caller
(`intelligence.ex:24`) invokes `SurgicalBriefing.build(path, concept)` — it
passes the **project path** where `prompt` is expected and the **prompt text**
where `project_path` is expected. The two arguments are reversed. The MCP
`briefing` tool therefore feeds a filesystem path into the semantic search and
a prose prompt into the path argument — it has never produced a correct
briefing. Correct call: `SurgicalBriefing.build(concept, path)`.

### Bug B — swapped arguments in `MCP.Dispatch.Intelligence.plan_validate/1`

`PlanValidator.validate/3` is defined `validate(plan, project_path, opts)`. The
caller (`intelligence.ex:65`) invokes `PlanValidator.validate(path, plan)` —
`plan` and `project_path` are reversed. Inside `validate`, `plan["modules_touched"]`
then runs against a string, raising, which the function's `rescue` swallows
into `{:ok, %{verdict: "error", ...}}`. The MCP `plan_validate` tool thus always
returns the `"error"` verdict. Correct call: `PlanValidator.validate(plan, path)`.

Both bugs are masked today: Bug B by the `rescue`, Bug A by `:skip` likely
being returned before the swap matters. If the Warning 3/4 diffs are applied
without also fixing the arg order, the warnings go away but the tools stay
broken. **Recommendation:** treat A and B as a small follow-up fix bundled with
Warnings 3 & 4 — but that is your call, and it touches `lib/` (out of this
order's stated scope).

---

## Item 4 — golden-fixture-drift tagged and excluded

The 8 failing `Giulia.AST.GoldenFixturesTest` tests are loop-generated from one
`test "golden: #{name}"` (`golden_fixtures_test.exs:51`); the module contains
only these 8 tests. They are tagged via `@moduletag :golden_fixture_drift` and
excluded from default runs by `exclude: [:golden_fixture_drift]` in
`test/test_helper.exs`.

- **Run them explicitly:** `mix test --include golden_fixture_drift`
- **Regeneration worklist + acceptance criteria:** `fixture-drift-backlog.md`
- **Acceptance for the fixture-regeneration PR:** regenerate the 8
  `*.expected.exs` files on Elixir 1.19.5, remove the `@moduletag` and the
  `exclude:` option, and verify all 8 pass under a plain `mix test`.

**Verification (fresh ArcadeDB 26.4.2):**

| Run | Result |
|-----|--------|
| `mix test` (default) | `2200 tests, 2 failures (8 excluded)` — 8 golden tests excluded; the 2 failures are the known-flaky `ApiAdversarialTest` indexer-warmup timeout |
| `mix test --include golden_fixture_drift` (scoped to the file) | `8 tests, 8 failures` — tag wiring confirmed |

> Diagnostic note: an interim full run showed 6 failures (2 `Arcade.VerifierTest`
> + 1 `Persistence.VerifierTest` + 3 flaky `ApiAdversarialTest`). The Verifier
> failures were ArcadeDB **state accumulation** — three consecutive full suites
> had been run against one long-lived ArcadeDB container. A fresh ArcadeDB
> 26.4.2 cleared all three (`15 tests, 0 failures` for both Verifier suites).
> Not a code regression, and unrelated to the Item 4 tagging change.

---

## Known characteristics — ArcadeDB state accumulation

**Observed (Item 4 verification, 2026-05-21):** three consecutive `mix test`
runs against the *same* long-lived ArcadeDB container produced 3 `VerifierTest`
failures (2 `Giulia.Storage.Arcade.VerifierTest` + 1 `Giulia.Persistence.VerifierTest`)
that did **not** occur on a single run. The failure signature was Arcade write
errors — `functions: %{error: N, ok: M}` on snapshot, leading to L3 holding
fewer edges than L1 (`count_parity: :l3_under_l1`).

**Restored by a fresh container:** stopping and recreating the ArcadeDB
container (`arcadedata/arcadedb:26.4.2`) cleared all three — both Verifier
suites then passed `15 tests, 0 failures`. So this is accumulated state, not a
code regression and not an ArcadeDB version issue (26.4.2 is clean fresh).

**Implication:**
- **Local dev:** running `mix test` many times in a row against one ArcadeDB
  container may surface intermittent `VerifierTest` failures as state piles up.
- **CI:** unaffected — each CI job starts a fresh ArcadeDB container, so no
  accumulation occurs across runs.

**Workaround until properly fixed:** `docker restart arcadedb` between extended
local test sessions. Proper fix (per-test/per-suite ArcadeDB teardown) is
tracked in `docs/orders/quality-tooling/test-isolation-backlog.md`.
