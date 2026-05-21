# Dialyzer — FIX-LATER Backlog

Worklist for a future Dialyzer-cleanup effort. 125 findings remaining after
Phase 2c (`mix dialyzer`, flags: `error_handling`, `missing_return`,
`extra_return`, `no_improper_lists`). None is a crash-on-every-call bug — the
4 of those were fixed in the Phase 2c commit. None blocks Phase 3 CI wiring.

See `phase-2-dialyzer.md` for the triage. Counts below are exact as of
2026-05-21.

## `pattern_match` — 48

"The pattern can never match the type." Mostly dead defensive clauses (e.g.
`{:error, _}` arms on functions that never return errors). **32 of the 48
cluster in two files** — `daemon/routers/knowledge.ex` (20) and
`mcp/dispatch/knowledge.ex` (12) — a systematic repeated clause shape; fixing
one likely informs the rest.

```
lib/giulia/context/indexer.ex:297          lib/giulia/context/indexer.ex:316
lib/giulia/context/indexer.ex:623          lib/giulia/core/project_context/history.ex:78
lib/giulia/daemon/routers/knowledge.ex:227 :257 :287 :317 :347 :377 :429 :459
lib/giulia/daemon/routers/knowledge.ex:495 :504 :548 :553 :598 :601 :606 :609
lib/giulia/daemon/routers/knowledge.ex:637 :667 :692 :807
lib/giulia/inference/tool_dispatch/special.ex:133
lib/giulia/intelligence/architect_brief.ex:278
lib/giulia/intelligence/preflight.ex:189
lib/giulia/knowledge/insights.ex:120       lib/giulia/knowledge/store.ex:268
lib/giulia/knowledge/topology.ex:152
lib/giulia/mcp/dispatch/knowledge.ex:98 :133 :146 :149 :168 :171 :186 :189
lib/giulia/mcp/dispatch/knowledge.ex:192 :195 :212 :224 :275
lib/giulia/persistence/verifier.ex:1       lib/giulia/runtime/ingest_store.ex:295
lib/giulia/tools/get_impact_map.ex:79      lib/giulia/tools/patch_function.ex:1
lib/giulia/tools/trace_path.ex:58
```

## `extra_range` — 20

`@spec` declares a wider return type than the function produces. Spec-tightening,
not a bug.

```
lib/giulia/knowledge/analyzer.ex:92        lib/giulia/knowledge/dead_code_classifier.ex:85
lib/giulia/knowledge/store.ex:163 :166 :209 :227
lib/giulia/knowledge/store/reader.ex:285 :291 :304
lib/giulia/mcp/dispatch/knowledge.ex:140 :252
lib/giulia/persistence/verifier.ex:51 :239 :331
lib/giulia/provider/anthropic.ex:51        lib/giulia/provider/gemini.ex:82
lib/giulia/provider/groq.ex:68             lib/giulia/provider/router.ex:158
lib/giulia/storage/arcade/client.ex:430 :501
```

## `missing_range` — 16

`@spec` omits a return type the function actually produces. Spec-tightening.

```
lib/giulia/ast/analysis.ex:84              lib/giulia/client/renderer.ex:11
lib/giulia/core/project_context/history.ex:32 :67
lib/giulia/inference/context_builder/helpers.ex:53
lib/giulia/inference/rename_mfa.ex:67
lib/giulia/knowledge/analyzer.ex:92 :106 :113
lib/giulia/knowledge/store/reader.ex:304 :310
lib/giulia/monitor/telemetry.ex:37         lib/giulia/provider/anthropic.ex:51
lib/giulia/tools/cycle_check.ex:70         lib/giulia/tools/get_impact_map.ex:51
lib/giulia/tools/trace_path.ex:51
```

## `pattern_match_cov` — 15

Clause coverage — a later clause already covered by an earlier one.

```
lib/giulia/ast/slicer.ex:246               lib/giulia/context/indexer.ex:634
lib/giulia/inference/response_parser.ex:114
lib/giulia/inference/tool_dispatch/executor.ex:70
lib/giulia/intelligence/architect_brief.ex:75 :98 :169 :186
lib/giulia/intelligence/plan_validator.ex:104 :117 :241
lib/giulia/intelligence/preflight.ex:221
lib/giulia/knowledge/insights/impact.ex:257
lib/giulia/knowledge/store/reader.ex:236   lib/giulia/runtime/inspector.ex:266
```

## `invalid_contract` — 10

`@spec` contradicts the function's success typing.

```
lib/giulia/ast/analysis.ex:19              lib/giulia/ast/processor.ex:103
lib/giulia/inference/engine/helpers.ex:49  lib/giulia/knowledge/analyzer.ex:141
lib/giulia/knowledge/insights.ex:24 :431
lib/giulia/knowledge/metrics.ex:25 :155 :273
lib/giulia/provider/ollama.ex:36
```

## `guard_fail` — 9

Guards that can never succeed — dead defensive checks (e.g.
`architect_brief.ex:116` `when non_neg_integer() === nil`).

```
lib/giulia/daemon/routers/knowledge.ex:30  lib/giulia/inference/escalation.ex:107
lib/giulia/intelligence/architect_brief.ex:85 :116 :117 :118 :280
lib/giulia/intelligence/plan_validator.ex:180
lib/giulia/mcp/dispatch/knowledge.ex:22
```

## `no_return` + `call` — 5 (2 linked legacy issues)

Two `\\ nil` default-arg convenience arities whose nil path fails a downstream
call; the `no_return`s are consequences. Lower priority than the fixed FIX-NOW
four — these are legacy/convenience arities, not crash-on-every-call tools.

```
lib/giulia.ex:25                  — status/0 -> Store.stats(nil)
lib/giulia/knowledge/store.ex:223 — struct_lifecycle/1 -> Reader.struct_lifecycle(_, nil)
lib/giulia/knowledge/store.ex:264 — no_return knock-on
```

## `unused_fun` — 1

```
lib/giulia/intelligence/architect_brief.ex:300 — extract_section/2 never called (dead code)
```

## `exact_eq` — 1

```
lib/giulia/persistence/verifier.ex:247 — map() == nil always false (dead branch)
```
