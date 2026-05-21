# Doc Reconciliation — Summary Report

**Date:** 2026-05-21
**Order:** `docs/orders/2026-05-21-doc-reconciliation.md` (stale; deleted after this reconciliation)
**Scope executed:** "Real items + Task 7" (per operator decision). Counts derived from code, no daemon.

---

## Headline finding: the order was largely stale

The order's premise — "documentation is still stamped v0.2.1/v0.2.2 and contains
the README 'no LLM inside' contradiction" — does **not** match the current repo.
Recent commits (`79e702a` "ARCHITECTURE restructure, README repositioning",
`5529661` "surface v0.3.8 additions") had already done the bulk of the
reconciliation. Verified task-by-task:

| Task | Order's premise | Actual state | Action |
|---|---|---|---|
| 1 — README "no LLM inside" | Callout `> **Giulia is read-only.**` exists | No such block; README already reconciled with a v0.3.8 deprecation note. `grep "no LLM inside"` → 0 hits | None needed |
| 2 — version stamps | README v0.2.1, ARCH v0.2.2, API v0.2.1 | README + ARCH already `Build 161 · v0.3.8`; only API.md lagged (`Build 160 · v0.3.7`) | API.md header fixed; `/health` example fixed; dates unified |
| 3 — endpoint/tool counts | "83+" / "85" / "71 tools" | Genuinely inconsistent everywhere AND inside API.md | **Real work — done** |
| 4 — L1/L2/L3 tiers | README collapses to two tiers, calls ArcadeDB "L2" | README already correct three-tier | One real bug fixed: `ARCHITECTURE.md` ASCII said "ArcadeDB L2 snapshots" |
| 5 — promote ARCH Section 5 | Subsections buried under Section 5 | Headings already clean monotonic `## 1`–`## 18` | None needed |
| 6 — add "Static Analysis Boundaries" | Section missing | Exists as `## 18. Known Blind Spots`, more thorough than the order's proposed text | None needed (see flag below) |
| 7 — document `:one_for_one` | No restart-strategy discussion | Confirmed absent | **Added — done** |
| 8 — archive self-analysis PDF | Stale PDF in `docs/` | No PDF exists anywhere under `docs/` | Moot (see below) |

---

## Files changed

| File | Change |
|---|---|
| `mix.exs` | Added top-of-file comment naming the 3 docs to keep version-synced (Task 2). |
| `README.md` | Header date `2026-04-29`→`2026-05-21`; endpoint count `85`→`88` (2 spots); MCP tool count `71`→`75` (2 spots). |
| `ARCHITECTURE.md` | Header date →`2026-05-21`; `85 API endpoints`→`88` (3 spots); `MCP server (71 tools)`→`75`; ASCII `ArcadeDB L2 snapshots`→`L3`; `MCP.ToolSchema` row `71`/`74`→`75`/`78`; Section 13 router table Index `9`→`10`, Knowledge `25`→`27`, Intelligence `5`→`6`, core endpoint `11`→`10`; **new `### Restart strategy` subsection** in Section 3. |
| `API.md` | Header `Build 160 · v0.3.7 · 2026-04-29`→`Build 161 · v0.3.8 · 2026-05-21`; `/health` example `version` `"0.6.0-build.137"`→`"v0.3.8.161"`; TOC Index `9`→`10`, Knowledge `24`→`27`, Intelligence `5`→`6`; body "largest category with 23 endpoints"→`27`; "How It Works" `All 74 @skill` reworded to 78/75; Quick Reference table (Index, Knowledge, Intelligence, Monitor, Discovery, MCP, Total) corrected; table note rewritten; "Excluded Endpoints" expanded with the REST/MCP gap explanation. |

No code was modified. `mix.exs` version/build were **not** bumped. No commit made.

---

## Facts verified against code

All counts derived from source, daemon down.

- **Version / build:** `mix.exs:4` `@version "0.3.8"`, `mix.exs:6` `@build 161`.
- **`/health` response format:** `lib/giulia/version.ex:20-22` — `short_version/0`
  returns `"v#{@version}.#{@build}"` → canonical value `"v0.3.8.161"`. The old
  API.md example `"0.6.0-build.137"` matched no code path.
- **REST endpoint count = 88.** 10 core routes in `lib/giulia/daemon/endpoint.ex`
  (excluding `/favicon.ico`, a non-API static route) + 78 sub-router routes.
  Per-router `@skill %{` counts: approval 2, discovery 4, index 10,
  intelligence 6, knowledge 27, monitor 7, runtime 16, search 3, transaction 3
  = 78. Cross-checked: API.md documents exactly 88 endpoints via `###` headings
  (10+10+27+6+16+3+3+2+7+4).
- **MCP tool count = 75.** `lib/giulia/mcp/tool_schema.ex` `all_tools/0` =
  78 router skills filtered by `mcp_compatible?/1`, which drops 3 monitor
  endpoints (`/api/monitor` + `/api/monitor/graph` return HTML,
  `/api/monitor/stream` is SSE). 78 − 3 = 75.
- **Supervision tree** (`lib/giulia/application.ex:67-191`): single
  `:one_for_one` `Giulia.Supervisor`; 5 tiers (base / heavy / inference /
  tail / MCP) — matches ARCHITECTURE Section 3.
- **`EtsKeeper`** (`lib/giulia/ets_keeper.ex:1-39`): real `:heir` process;
  `Context.Store` / `Knowledge.Store` register it so ETS survives owner crash.
- **`Arcade.Indexer` reconcile** (`lib/giulia/storage/arcade/indexer.ex:23-30`):
  5-minute reconcile pass backfills snapshots missed by dropped `{:graph_ready}`
  `send/2` messages. (Order Task 7 mis-attributed this to the Consolidator —
  corrected in the written subsection.)
- **`GIULIA.md:36-57`**: "Restart-time state recovery" invariant — every state
  owner must be self-recovering or `:heir`-protected. The new subsection cites it.

---

## Items flagged for human review

1. **The order itself is stale.** It was written against a pre-`79e702a`
   snapshot. Tasks 1, 5, 6, 8 were already done or moot before this pass. No
   `VERIFY:` markers were committed; nothing was guessed.

2. **Task 6 — do NOT apply as written.** The order's proposed "Static Analysis
   Boundaries" text (variable dispatch / Mox / `.heex` / runtime config, plus a
   "5.6%" figure) would be a **downgrade**. `ARCHITECTURE.md ## 18. Known Blind
   Spots` already covers this with a 7-row table, a residual classifier
   (`DeadCodeClassifier`), and a real per-codebase baseline table. The order's
   "5.6%" figure appears nowhere in the codebase or docs — its provenance is
   unknown. Recommend the order's Task 6 be marked obsolete.

3. **Scope boundary.** Per the "Real items + Task 7" decision, version-stamp
   fixes were applied only to the 3 primary docs. Other `.md` files
   (`SKILL.md`, `INSTALLATION.md`, `SESSION_STATUS.md`, `docs/*.md`) were **not**
   swept for stale version refs. If a full-tree sweep is wanted, that is a
   separate pass.

4. **ARCHITECTURE Document History** (`ARCHITECTURE.md:~1008`) still shows the
   Build 161 row dated `2026-04-29`, while the header now reads `2026-05-21`.
   Left intentionally — Document History is a per-build narrative log and this
   reconciliation is a within-build correction, not a new build. Flagging in
   case you want a "doc reconciliation" row added.

5. **`/favicon.ico`** is a real registered route in `endpoint.ex` but is not an
   API endpoint. The canonical count of 88 excludes it; this is now stated
   explicitly in API.md's "Excluded Endpoints" section.

---

## Self-analysis PDF status

No PDF exists anywhere under `docs/` (`find docs -iname '*.pdf'` → empty).
Task 8 is moot — nothing to archive, no links to update. The repo root has two
markdown reports (`Giulia_REPORT_2026031814.md`, `Giulia_REPORT_2026032408.md`),
but those are not PDFs and not what Task 8 describes.

**TODO for operator:** if a self-analysis artifact is desired, generate one
against the current build (v0.3.8 / Build 161). Regeneration requires running
Giulia against itself — an operator decision, not done here.

---

## Suggested follow-ups

- The stale order and its `_tmp.html` scratch file were deleted after this
  pass; only this report remains in `docs/orders/`.
- The TOC at `API.md:31` lists "11. MCP" with no count; the MCP section is
  prose, not endpoints. Consistent, but if a count is wanted there it should be
  "75 tools, 5 resources" — not added here (out of scope).
