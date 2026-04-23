# Giulia - Giulia Constitution

This file defines the rules and context for Giulia when working in this project.
Giulia will read this file on every interaction and enforce these guidelines.

## Project Identity

- **Name**: Giulia
- **Root**: /projects/Giulia
- **Created**: 2026-02-04

## Tech Stack

- **Language**: Elixir
- **Framework**: Pure Elixir


## Architectural Guidelines

<!-- Add your project-specific rules here -->

- [ ] Define preferred testing approach (ExUnit, Mox, Stub)
- [ ] Define code style preferences
- [ ] Define architectural taboos (things Giulia should NEVER do)

## Taboos (Never Do This)

<!-- Examples:
- Never use `import` for Phoenix controllers, always use `alias`
- Never use umbrella project structure
- Never add dependencies without explicit approval
-->

## Preferred Patterns

<!-- Examples:
- Use context modules for business logic
- Prefer pipe operators for data transformation
- Use Ecto.Multi for database transactions
-->

## File Conventions

- Test files: `test/**/*_test.exs`
- Config files: `config/*.exs`

## Empirical refactor loop (how Giulia work is done)

Improvements to detector precision (dead_code, change_risk, coupling,
unprotected_hubs, etc.) follow a fixed five-step loop. Each step is
mandatory. The loop produces defensible numbers and — critically —
surfaces extraction bugs that would otherwise hide under dispatch-
pattern rationalizations.

1. **Predict.** Before writing code, commit to a quantitative
   hypothesis against a real codebase (the canonical target is
   `analytics-master`, Plausible CE).
2. **Implement the vertical slice.** One dispatch pattern or
   correctness fix at a time. Keep scope narrow.
3. **Measure.** Rebuild, wipe per-project cache, cold-rescan, pull
   the same endpoints the baseline used. Report the delta.
4. **Skeptically categorize the residual.** Every remaining false-
   positive cluster that doesn't obviously match a KNOWN dispatch
   pattern gets 10 minutes of `grep` + visual audit before being
   filed as "future work." If static callers exist for "dead"
   functions, it's an extraction bug, not a dispatch pattern —
   fix it first, it affects every detector.
5. **Diff-the-report.** Re-run the full audit and diff against the
   previous baseline. The diff IS the postmortem; it names the bug's
   topology (peripheral vs. core edges, which metrics shifted).

Step 4 is the non-negotiable one — it exists because on 2026-04-23
three separate walkers were found to share a "first-module-wins" bug
that would have stayed hidden if the residual after the `defimpl`
slice had been filed as "future dispatch slices" without a sanity
check. See `memory:feedback_slice_methodology` in `.claude/` for the
full retrospective.

---
*This constitution is loaded by Giulia on every interaction.*
*Edit this file to change how Giulia behaves in this project.*
