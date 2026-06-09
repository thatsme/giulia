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

## CubDB shared-tmp path collision under concurrency

`LoaderTest` (and sibling CubDB suites) share the `/tmp/giulia_test_cubdb/<hash>`
tree. Under full-suite concurrency a path component can already exist as a file,
so `File.mkdir_p!/1` raises `:enotdir` and `Store.do_open/1` crashes mid-`:close`.

**Evidence:** full-suite run (build 164) failed
`Giulia.Persistence.LoaderTest` "cold start returns cold_start when no CubDB
exists" (`test/giulia/persistence/loader_test.exs:27`) with
`** (File.Error) could not make directory (with -p) ".../98652010": not a
directory`. Re-running the test in isolation passed (0 failures) — confirms a
concurrency collision on the shared tmp path, not a logic fault.

**Scope of a fix:** give each CubDB test a unique, non-overlapping tmp root
(e.g. per-test tmp_dir) instead of a shared `/tmp/giulia_test_cubdb` hash space.

**Status:** open.

## Integration setup: fixed 5s readiness poll races the indexer warm-start

`ApiAdversarialTest` setup calls `ready?/1`, which does
`GenServer.call(Giulia.Context.Indexer, {:status, ...}, 5000)`. When the indexer
is mid-warm-start of the full `/projects/Giulia` mount, status can take longer
than 5s, so setup times out and the test fails *before its body runs*.

**Evidence:** full-suite run (build 164) failed
`Giulia.Integration.ApiAdversarialTest` "GET /api/knowledge/dead_code detects
unused functions" (`test/integration/api_adversarial_test.exs:336`) with
`** (exit) ... GenServer.call(Giulia.Context.Indexer, {:status, ...}, 5000) ...
time out` in `__ex_unit_setup_0`. Logs show the graph rebuild finished ~1s later;
isolated re-run passed, with the dead_code handler returning 200 in 7.9s — longer
than the 5s poll, which is the race. The handler/dead_code logic is not at fault.

**Scope of a fix:** wait for an explicit warm-start/ready signal instead of a
fixed-timeout `:status` poll, or isolate the integration suite from the live
`/projects/Giulia` mount so setup isn't racing a real scan.

**Status:** open.
