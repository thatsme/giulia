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

## Invariants

### Restart-time state recovery

Every long-lived state owner (GenServer, Agent, anything holding ETS,
in-memory caches, or registered subscriptions) must be either:

  (a) **self-recovering on restart from an authoritative source** —
      filesystem, a registry, a CubDB cache, ArcadeDB, or another
      process's state — such that `init/1` reconstructs whatever the
      previous incarnation held; OR

  (b) **using `:heir` on its ETS table** so the data survives the
      owner's death and the next incarnation reclaims it.

**Silent state loss after restart is forbidden.** A supervisor's
restart must restore correctness, not just keep the API responding.
If `list_X/0` returns a wrong answer between a crash and the next
write, the design is wrong — not the operator's tolerance for it.

The same rule applies to fire-and-forget messages between supervised
processes (`send/2` to a `whereis` lookup): unacknowledged delivery
without a reconciliation path is silent state loss. Either log every
miss *and* reconcile periodically, or use a durable queue.

### Agent-driven architectural review

Every flagged finding from an agent-produced architectural audit
(supervision tree, restart semantics, concurrency, etc.) must be
verified against the actual code before acting on it. Across three
audit rounds on this codebase, roughly **one third of agent findings
turned out to be misreads on inspection** — citing functions that
existed differently than described, severities scaled up from
plausible to alarming, or "leaks" that were already bounded.

Agents are good at pattern-matching architectural smells, but the
smell-to-bug ratio is around 60–70%. Skipping verification to "just
ship the fix" produces real regressions and wastes review cycles
on imaginary problems. The audit is the cheap part; verification is
the part that earns the audit.

When in doubt: open the file, read the function, then act.

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
