# Test Isolation — Backlog

Tracked test-isolation issues uncovered during the quality-tooling work stream.

## ArcadeDB state accumulation across consecutive runs

ArcadeDB tests don't fully clean up between runs; state accumulates across
consecutive `mix test` invocations against a single container. Investigate
per-test or per-suite teardown of ArcadeDB schema and records.

**Evidence:** three consecutive `mix test` runs against one long-lived ArcadeDB
container surfaced 3 `VerifierTest` failures (2 `Arcade.VerifierTest` +
1 `Persistence.VerifierTest`) absent on a single run; a fresh container cleared
them. See the "Known characteristics — ArcadeDB state accumulation" section of
`_baseline.md`.

**Scope of a fix:**
- Tear down ArcadeDB records (and/or the test database/schema) between tests or
  suites so each run starts from a known-empty state.
- Confirm the Verifier suites are deterministic across N back-to-back runs.

**Status:** open — not addressed in the quality-tooling order.
