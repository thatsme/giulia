# Changelog

All notable changes to Giulia that affect observable behavior, API contracts,
analysis output correctness, or cached-data compatibility. Internal refactors
and test-only changes are not listed here — see the git log for those.

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
