# MCP Dispatch — Integration Test Backlog

## Structural finding

Across the Phase 2 quality-tooling work, **6 real bugs** were found in
`lib/giulia/mcp/dispatch/` — every one a call-contract mismatch between a
dispatch handler and the underlying function it delegates to:

| Bug | Location | Defect | Surfaced by | Fixed in |
|-----|----------|--------|-------------|----------|
| A | `intelligence.ex` `briefing/1` | args swapped: `build(path, concept)` vs def `build(prompt, project_path)` | `compile --warnings-as-errors` | `3f520db` |
| B | `intelligence.ex` `plan_validate/1` | args swapped: `validate(path, plan)` vs def `validate(plan, project_path)` | `compile --warnings-as-errors` | `3f520db` |
| 1 | `search.ex` `semantic/1` | `length/1` on a map result | Dialyzer `call` | Phase 2c commit |
| 2 | `runtime.ex` `history/1` | integer passed where `Keyword.t()` expected | Dialyzer `call` | Phase 2c commit |
| 3 | `runtime.ex` `profiles/1` | integer passed where `Keyword.t()` expected | Dialyzer `call` | Phase 2c commit |
| 4 | `search.ex` `text/1` | string + sandbox passed where `(map/struct, opts)` expected; result double-wrapped | Dialyzer `call` | Phase 2c commit |

Every one of these is a tool that **never worked** — it would crash or return
garbage on its first real call. None was caught before Phase 2 because **the MCP
dispatch layer has no integration tests** against the functions it dispatches
to. The existing `test/giulia/mcp/dispatch/` tests cover required-param handling
and tool-schema shape only — not the dispatch → underlying-function execution
path. Static analysis (strict compile, Dialyzer) caught all 6; a single
happy-path test per tool would have caught them at write time.

## Recommendation

Each MCP dispatch tool should have, at minimum, **one happy-path integration
test** that exercises the full dispatch → underlying-function path with a
realistic argument map and asserts the shape of the result. This catches
exactly the class of drift above: call-contract mismatches that strict compile
and Dialyzer only find opportunistically.

## Effort

The MCP layer exposes on the order of ~75 tools. Per-tool a happy-path test is
small, but ~75 of them is a significant body of work — best prioritised as its
own work stream, not folded into a phase here. High value: it converts an
entire class of "shipped but broken" bugs into write-time failures.

This file records the structural observation. The per-tool test list is left
for the cleanup PR to enumerate and prioritise — enumerating all 75 tools here
would be noise; the observation is the artifact.

Date: 2026-05-21.
