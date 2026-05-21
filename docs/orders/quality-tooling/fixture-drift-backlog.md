# Golden-Fixture Drift — Regeneration Backlog

Worklist for the future PR that regenerates the AST golden fixtures against
the pinned Elixir 1.19.5 toolchain.

## Why these fail

`Giulia.AST.GoldenFixturesTest` diffs `Processor.analyze/2` output against
frozen `*.expected.exs` terms. The frozen terms were generated under an older
Elixir; Elixir 1.19 changed AST node metadata, so every fixture now drifts.
This is a toolchain change, not an extraction regression — confirmed during the
quality-tooling baseline (see `_baseline.md`).

All 8 tests are excluded from default runs via `@moduletag :golden_fixture_drift`
(set in `test/giulia/ast/golden_fixtures_test.exs`) and the
`exclude: [:golden_fixture_drift]` option in `test/test_helper.exs`.

## The 8 tagged tests

All 8 are loop-generated from a single `test "golden: #{name}"` at
`test/giulia/ast/golden_fixtures_test.exs:51`; the names come from the
`@fixture_cases` list at lines 38-47. Each has a source `.ex` and a frozen
`.expected.exs` under `test/fixtures/extraction/`.

| # | Test | `@fixture_cases` entry | Golden file to regenerate |
|---|------|------------------------|---------------------------|
| 1 | `golden: predicate_bang_default_args` | `golden_fixtures_test.exs:39` | `test/fixtures/extraction/predicate_bang_default_args.expected.exs` |
| 2 | `golden: moduledoc_variants` | `golden_fixtures_test.exs:40` | `test/fixtures/extraction/moduledoc_variants.expected.exs` |
| 3 | `golden: framework_callbacks` | `golden_fixtures_test.exs:41` | `test/fixtures/extraction/framework_callbacks.expected.exs` |
| 4 | `golden: protocols_defimpl` | `golden_fixtures_test.exs:42` | `test/fixtures/extraction/protocols_defimpl.expected.exs` |
| 5 | `golden: protocols_defimpl_multi` | `golden_fixtures_test.exs:43` | `test/fixtures/extraction/protocols_defimpl_multi.expected.exs` |
| 6 | `golden: macros_guards` | `golden_fixtures_test.exs:44` | `test/fixtures/extraction/macros_guards.expected.exs` |
| 7 | `golden: nested_modules` | `golden_fixtures_test.exs:45` | `test/fixtures/extraction/nested_modules.expected.exs` |
| 8 | `golden: macro_injected_templates` | `golden_fixtures_test.exs:46` | `test/fixtures/extraction/macro_injected_templates.expected.exs` |

## Regeneration procedure

1. On the pinned toolchain (Elixir 1.19.5 / OTP 27.3.4.11), regenerate the
   frozen terms — the test module supports this directly:

       GOLDEN_UPDATE=1 mix test --include golden_fixture_drift test/giulia/ast/golden_fixtures_test.exs

   This rewrites every `*.expected.exs` and flunks so it never passes silently.

2. Review the diff of the 8 `.expected.exs` files — confirm the changes are
   only AST-metadata churn, not real extraction drift.

3. Remove `@moduletag :golden_fixture_drift` from
   `test/giulia/ast/golden_fixtures_test.exs` and the
   `exclude: [:golden_fixture_drift]` option from `test/test_helper.exs`.

## Acceptance criteria for the regeneration PR

- The `@moduletag :golden_fixture_drift` tag is removed from the 8 tests.
- `exclude: [:golden_fixture_drift]` is removed from `test/test_helper.exs`.
- All 8 tests pass under `mix test` on Elixir 1.19.5 with no tag/exclude.
- The 8 regenerated `.expected.exs` diffs are reviewed and contain only
  metadata churn.
