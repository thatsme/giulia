# Session Status — Conventions Analyzer

## Branch
`feature/conventions-analyzer` (created from `main`)

## Status: COMPLETE — ready for merge

## What was done
1. Created `lib/giulia/knowledge/conventions.ex` — full analyzer with 12 rules (Tier 1 metadata + Tier 2 AST walk)
2. Wired into `analyzer.ex` (defdelegate), `store.ex` (defdelegate to Reader), `reader.ex` (direct call, no cache)
3. Added `GET /api/knowledge/conventions` route in `routers/knowledge.ex` with @skill annotation
4. Docker build passes clean (144 files compiled, 0 warnings)
5. Endpoint responds with correct JSON structure and all 12 rules

## Bugs fixed this session
- **Stale cache**: Reader was caching conventions results, returning 0 violations after re-indexing. Removed cache (conventions depends on mutable all_asts data).
- **Single-value pipe false positives**: Pipe chains like `conn |> A |> B` had inner nodes wrongly flagged. Two-phase meta-tracking now correctly identifies chain members. Fixed 354 false positives.

## Validation
- Tested against AlexClaw: 415 violations (9 errors, 120 warnings, 286 info) — all verified real
- Tested against Giulia: 285 violations (1 error, 104 warnings, 180 info) — all verified real
- Module filter works correctly
- Both Tier 1 (metadata) and Tier 2 (AST pattern) checks validated against source code
- Full test suite: 1732 tests, 4 failures (all pre-existing flaky, zero regressions)

## Files modified
- `lib/giulia/knowledge/conventions.ex` (NEW)
- `lib/giulia/knowledge/analyzer.ex` (added defdelegate)
- `lib/giulia/knowledge/store.ex` (added find_conventions)
- `lib/giulia/knowledge/store/reader.ex` (added find_conventions — no cache)
- `lib/giulia/daemon/routers/knowledge.ex` (added /conventions route)

## Stash
`git stash` has the CODING_CONVENTIONS.md changes from main (unrelated to this branch)
