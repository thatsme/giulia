# Phase 2c — Dialyzer Triage and Decisions (final)

Order: `docs/orders/2026-05-21-quality-tooling.md` | Triage: 2026-05-21
Decisions applied: 2026-05-21
Tool: `dialyxir 1.4.7`. PLT: `priv/plts/giulia.plt` (5.9 MB, 2013 modules).
Raw output: `_dialyzer_raw.txt`, `_dialyzer_plt.txt` — gitignored.

Initial run: **187 warnings** (flags: `unmatched_returns`, `error_handling`,
`missing_return`, `extra_return`, `no_improper_lists`).

## Warnings by type (initial 187)

| Type | Count |
|------|------:|
| `unmatched_return` | 50 |
| `pattern_match` | 48 |
| `extra_range` | 24 |
| `missing_range` | 16 |
| `pattern_match_cov` | 15 |
| `invalid_contract` | 10 |
| `guard_fail` | 9 |
| `call` | 7 |
| `no_return` | 5 |
| `unused_fun` | 2 |
| `exact_eq` | 1 |

## Decision — `:unmatched_returns` flag dropped

`:unmatched_returns` produced **50 of 187 findings (27%)**, spread broadly
(context/ 8, persistence/ 7, core/ 6, runtime/ 5, …), almost all intentional
fire-and-forget calls (`Logger`, `GenServer.cast`, telemetry, ETS writes). It is
the lowest-signal of the five flags — it fires on pattern, not risk.

**Decision (2026-05-21): dropped** from `dialyzer/0` in `mix.exs`, with a
rationale comment. The four higher-signal flags are kept. 187 → 137.

## FIX-NOW — 4 bugs fixed in the Phase 2c commit (all `mcp/dispatch/`)

Dialyzer's `call` warnings surfaced four broken MCP-dispatch tools — the same
class as the Phase 2 swapped-argument bugs A & B. The MCP dispatch layer was
written without integration exercise (see `mcp-integration-test-backlog.md`).

1. **`mcp/dispatch/search.ex:31`** — `semantic/1` called `length/1` on the
   **map** `%{modules:, functions:}` returned by `SemanticIndex.search/3`.
   Raised on every successful search. Fixed: `count` =
   `length(results.modules) + length(results.functions)`.
2. **`mcp/dispatch/runtime.ex:48`** — `history/1` passed an **integer** to
   `Collector.history/2`, whose 2nd arg is `Keyword.t()` (`Keyword.get(opts,
   :last, …)`). Fixed: `Collector.history(node_ref, last: last_n)`.
3. **`mcp/dispatch/runtime.ex:89`** — `profiles/1` passed an **integer** to
   `Monitor.list_profiles/1`, whose arg is `Keyword.t()` (`Keyword.get(opts,
   :limit, …)`). Fixed: `Monitor.list_profiles(limit: limit)`.
4. **`mcp/dispatch/search.ex:18`** — `text/1` passed a bare string + a
   `%PathSandbox{}` to `SearchCode.execute/2`, whose contract is
   `(map() | %SearchCode{}, keyword())`; it also double-wrapped the already
   `{:ok, _}`-shaped result. Fixed: pass `%{"pattern" => pattern}` +
   `[sandbox: sandbox]`, and `case` on the result instead of re-wrapping.

`mix test` after all four: 2200 tests, 2 failures (both the flaky
`ApiAdversarialTest` timeout) — no regression; no test was relying on the broken
behaviour (consistent with the missing-integration-test finding).

### Methodology correction

The initial triage table partitioned the 7 `call` findings as
"3 FIX-NOW / 2 FIX-LATER / 2 IGNORE" — an arithmetic error: only 1 is IGNORE
(`writer.ex:305`), and `writer.ex:319` is `unused_fun`, not `call`. The correct
split is **4 FIX-NOW / 2 FIX-LATER / 1 IGNORE**. `search.ex:18` was
uncategorized in the first pass. It was caught at apply time — while re-running
Dialyzer after fixes 1–3 — verified as a genuine fourth bug of the same class,
and corrected here.

## IGNORE — 2 findings (CubDB false positive), applied

`writer.ex:305` (`call` — `CubDB.put_multi/2`) and `:319` (`unused_fun` —
`update_merkle_tree/3`) are one linked Dialyzer false positive: `CubDB.put_multi`'s
typespec is narrower than its runtime behaviour, so Dialyzer reads the call as
failing and the code after it as unreachable. Persistence + warm-restore suites
pass — `put_multi` with a list of pairs works at runtime.

**Applied** — two entries in `.dialyzer_ignore.exs`, each with a rationale
comment. Re-run confirms "Unnecessary Skips: 0" (both filters match).

## FIX-LATER — 125 findings (backlog)

All remaining findings — `pattern_match` (48), `extra_range` (20),
`missing_range` (16), `pattern_match_cov` (15), `invalid_contract` (10),
`guard_fail` (9), plus 2 legacy `call`/3 `no_return`, 1 `unused_fun`, 1
`exact_eq`. None is a crash-on-every-call bug. Full file:line worklist in
`dialyzer-backlog.md`.

## Final state

| Stage | Findings | Change |
|-------|---------:|--------|
| Initial Phase 2c run | 187 | — |
| `:unmatched_returns` flag dropped | 137 | −50 |
| 4 FIX-NOW bugs fixed (incl. paired `no_return` / knock-on warnings) | 127 | −10 |
| 2 CubDB false positives ignored in `.dialyzer_ignore.exs` | **125** | −2 |

`mix dialyzer` now reports **125 findings** — all FIX-LATER backlog.

## Cross-reference

The four FIX-NOW bugs + Phase 2's bugs A & B make **6 call-contract bugs** in
`mcp/dispatch/`, all caught by static analysis rather than tests. The
structural gap — no integration tests for the MCP dispatch layer — is recorded
in `mcp-integration-test-backlog.md`.

## P2c status

- FIX-NOW: 4 — fixed in the Phase 2c commit (`search.ex` ×2, `runtime.ex` ×2).
- IGNORE: 2 — CubDB `put_multi` false positive, applied to `.dialyzer_ignore.exs`.
- `:unmatched_returns`: flag dropped (50 findings, 27%).
- FIX-LATER: 125 — `dialyzer-backlog.md`.
- Structural: `mcp-integration-test-backlog.md`.
