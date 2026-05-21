# Phase 1 Report — Wire Up Quality Tooling

Order: `docs/orders/2026-05-21-quality-tooling.md` | Date: 2026-05-21
Commit: `a29e89c` — "build: wire up Credo, Dialyzer, Sobelow, ex_doc as dev/test deps"

## Dependencies installed (exact versions from `mix.lock`)

| Dependency | mix.exs spec | Resolved | Notes |
|------------|--------------|----------|-------|
| `credo` | `~> 1.7` | **1.7.18** | within spec |
| `dialyxir` | `~> 1.4` | **1.4.7** | within spec |
| `sobelow` | `~> 0.13` | **0.14.1** | within spec — `~> 0.13` permits `< 1.0.0`; not a new major, spec left unchanged |
| `ex_doc` | `~> 0.34` | **0.40.2** | within spec — `~> 0.34` permits `< 1.0.0`; spec left unchanged |

Transitive deps added by the above: `bunt 1.0.0`, `earmark_parser 1.4.44`,
`erlex 0.2.9`, `makeup 1.2.1`, `makeup_elixir 1.0.1`, `makeup_erlang 1.1.0`,
`nimble_parsec 1.4.2`.

No spec needed bumping — all four resolved inside the order's proposed ranges.

## `mix compile`

**Pass** — `Generated giulia app`, **0 warnings**. `mix compile --warnings-as-errors`
also passes clean.

This is better than the order's P0 baseline (which recorded *4 warnings /
`--warnings-as-errors` FAIL*). The 4 warnings were resolved earlier in this work
stream (commits `9f74464`, `3f520db`) before Phase 1 began — not a regression,
an improvement carried in.

## `mix test`

**`2200 tests, 1 failure (8 excluded)`** — run on a freshly-restarted ArcadeDB
26.4.2.

- 8 excluded = the `@golden_fixture_drift`-tagged tests (commit `6f759ab`).
- 1 failure = `Giulia.Integration.ApiAdversarialTest` — the known-flaky
  indexer-warmup timeout (`GenServer.call(Giulia.Context.Indexer, ...)` 5s
  timeout in setup). Range observed across the work stream is 0–3 per run.

Matches baseline — adding the four dev/test deps caused no test change.

## Files created / modified and committed (`a29e89c`)

| File | Change |
|------|--------|
| `mix.exs` | 4 deps added; `project/0` extended with `aliases`, `dialyzer`, `preferred_cli_env`, `docs`; private `aliases/0`, `dialyzer/0`, `docs/0` added |
| `mix.lock` | 11 new locked entries (4 tools + 7 transitive) |
| `.credo.exs` | generated via `mix credo gen.config`; then `strict: true` and `MaxLineLength.max_length: 100` — no other checks touched |
| `.dialyzer_ignore.exs` | empty list with explanatory header comment |
| `.sobelow-conf` | non-Phoenix defaults (`router: ""`, `exit: "Low"`, `threshold: "low"`) |
| `priv/plts/.gitkeep` | PLT cache directory placeholder |
| `.gitignore` | `priv/plts/*.plt` and `priv/plts/*.plt.hash` excluded |

## Verification performed

- `mix deps.get` — resolved cleanly, no conflicts.
- `mix deps.compile` — all new deps compiled.
- `mix compile` — clean (see above).
- `mix help check` / `check.strict` / `check.fast` — all three aliases
  registered and print the expected step lists.
- `mix test` — see above.

## Anything unexpected

Nothing. Two minor notes:
- `sobelow` and `ex_doc` resolved to versions numerically higher than the
  order's example specs (`0.14.1` vs `~> 0.13`, `0.40.2` vs `~> 0.34`), but
  both are within the `~>` ranges — `~> 0.x` permits anything `< 1.0.0`. No
  action needed; recorded here for transparency.
- All five `docs/0` extras files (`README.md`, `ARCHITECTURE.md`, `API.md`,
  `CONTRIBUTING.md`, `SECURITY.md`) exist, so the `docs/0` config is valid as
  written. The `source_url` (`github.com/thatsme/giulia`) matches `git remote`.

The commit is inert: no enforcement is active. `mix compile`, `mix test`, and
existing developer workflows are unchanged. The `check` aliases exist but are
not yet wired into CI or git hooks.

## Stopping point P1

Phase 1 complete. Awaiting "proceed to Phase 2" before running the tools and
triaging findings.
