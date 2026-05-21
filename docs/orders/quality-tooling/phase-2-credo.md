# Phase 2a — Credo Triage and Decisions (final)

Order: `docs/orders/2026-05-21-quality-tooling.md` | Triage: 2026-05-21
Decisions applied: 2026-05-21
Tool: `credo 1.7.18`, run as `mix credo --strict` (config `.credo.exs`, `strict: true`).
Raw output: `_credo_raw.txt` (oneline), `_credo_full.txt` (full) — both gitignored.

Initial run analysed 321 files / 3039 mods+funs with 69 checks. **856 findings.**

## Findings by category (initial 856)

| Severity | Count | Notes |
|----------|-------|-------|
| Software Design `[D]` | 323 | 322 of them one check (`Design.AliasUsage`) |
| Refactoring `[F]` | 296 | nesting + complexity dominate |
| Readability `[R]` | 157 | line length + alias ordering dominate |
| Consistency `[C]` | 52 | all one check (`Consistency.LineEndings`) |
| Warning `[W]` | 28 | 27 perf, 1 fixture false-positive |
| **Total** | **856** | |

## Top checks per category (initial)

**Software Design `[D]` — 323**
1. `Design.AliasUsage` — "Nested modules could be aliased" — **322**
2. `Design.TagTODO` — "Found a TODO tag in a comment" — 1

**Refactoring `[F]` — 296**
1. `Refactor.Nesting` — "Function body is nested too deep" — **154**
2. `Refactor.CyclomaticComplexity` — "Function is too complex" — **66**
3. `Refactor.MapJoin` — "`Enum.map_join` more efficient than `map |> join`" — **51**
4. `Refactor.UnlessWithElse` — "unless should avoid `else`" — 7
5. `Refactor.CondStatements` — "cond needs ≥2 conditions" — 6
   *(tail: RejectReject 5, Apply 5, WithClauses-redundant 2)*

**Readability `[R]` — 157**
1. `Readability.MaxLineLength` — "Line too long (max 100)" — **86**
2. `Readability.AliasOrder` — "alias not alphabetically ordered" — **33**
3. `Readability.PreferImplicitTry` — "prefer implicit `try`" — **27**
4. `Readability.StringSigils` — "many quotes, use a sigil" — 5
5. `Readability.ModuleDoc` — "module needs `@moduledoc`" — 3
   *(tail: WithClauses-one-clause 2, LargeNumbers 1)*

**Consistency `[C]` — 52**
1. `Consistency.LineEndings` — "file uses unix endings, most use windows" — **52**

**Warning `[W]` — 28**
1. `Warning.ExpensiveEmptyEnumCheck` — "`length/1` is expensive, compare to `[]`" — **27**
2. `Warning.IoInspect` — "no `IO.inspect/1` calls" — 1

## Triage and decisions

### FIX-NOW — 0 items

Credo surfaced **no correctness bugs** — no dead clauses, no unreachable code,
no real-bug warnings. Every finding is style / refactoring / consistency debt.
This matches the order's expectation ("Credo doesn't find many of these").

The 4 genuine bugs in this work stream (the 4 compile warnings, incl. the two
swapped-argument MCP bugs) were caught earlier by `mix compile
--warnings-as-errors`, not by Credo — fixed in commits `9f74464` and `3f520db`.

The single `Warning.IoInspect` hit is **not** a real debugging leftover — it is
in `test/fixtures/extraction/macros_guards.ex`, a deliberate sample-code file
the AST extractor is tested against (see IGNORE below).

### IGNORE — `test/fixtures/` excluded from Credo (1 applied)

`test/fixtures/extraction/*.ex` are deliberate sample-code files fed to the AST
extractor in golden tests — they intentionally contain non-idiomatic code so
extraction is exercised against it. Linting them is a false-positive source.
They produced exactly 4 findings:

- 3× `Readability.ModuleDoc` (fixture modules are minimal by design)
- 1× `Warning.IoInspect` (`macros_guards.ex` — intentional fixture content)

**Applied** — `test/fixtures/` added to `files.excluded` in `.credo.exs`:

```elixir
excluded: [
  ~r"/_build/",
  ~r"/deps/",
  ~r"/node_modules/",
  ~r"/test/fixtures/"
]
```

Effect: removes the 4 fixture findings; scanned file count 321 → 305.

### Design.AliasUsage — disabled (decision, 2026-05-21)

322 findings (38% of the initial total) — one check. **Decision: disabled** in
`.credo.exs` (`{Credo.Check.Design.AliasUsage, false}`).

**Rationale — verified, not assumed.** Two evidence gathers backed this:

1. **Sample of 10 findings, code read at each site:** none was a true
   disambiguation case — no sampled file used two same-named sibling modules,
   so aliasing would not create in-file ambiguity anywhere. Every finding is a
   legitimately-aliasable module; the check produces **zero false positives**.
2. **Codebase-wide tally** of fully-qualified `Giulia.*` references vs `alias
   Giulia.*` declarations in `lib/`:

   | Pattern | Count |
   |---------|------:|
   | Fully-qualified `Giulia.*` references | **1011** |
   | `alias Giulia.*` declarations | **182** |

   Fully-qualified usage outnumbers aliasing roughly **5.5 : 1** (≈3–4 : 1 even
   after discounting `defmodule`/`alias`-line self-matches).

The 322 findings are therefore **representative of the dominant codebase
style**, not stragglers worth a 322-edit refactor. `AliasUsage` is disabled by
deliberate project decision: Giulia uses fully-qualified module names inline as
a convention.

### Consistency.LineEndings — resolved by `.gitattributes`

52 files were on LF while the working-tree majority was CRLF — a Windows-host
artifact (`core.autocrlf=true` checking blobs out as CRLF; files written
directly during this work stream stayed LF on disk).

**Resolved** by adding `.gitattributes` (commit **`dda4217`**) enforcing LF for
all text file types (CRLF preserved for `.bat`/`.cmd`/`.ps1`). After that
commit landed, the working tree was re-materialized against the new policy with
`git rm --cached -rq . && git reset --hard` — 292 files normalized CRLF→LF
locally; CI/fresh checkouts get LF automatically.

Incidental side effect: **−4 `Readability.MaxLineLength`** findings. Four lines
sat exactly at the 100-char limit; the trailing `\r` of their CRLF ending had
pushed them to 101 and tripped the check. Removing the CR dropped them back
under the limit — a correct, if tiny, improvement.

### FIX-LATER — 474 items (backlog)

All remaining findings are real but non-urgent style/refactor debt. None is a
correctness issue. See the "FIX-LATER backlog" section below for the worklist.

## Final state

| Stage | Findings | Change |
|-------|---------:|--------|
| Initial Phase 2a run | 856 | — |
| `.gitattributes` resolves `Consistency.LineEndings` (commit `dda4217`) | 804 | −52 |
| Incidental `MaxLineLength` drop (CRLF padding removed, same commit) | 800 | −4 |
| `Design.AliasUsage` disabled in `.credo.exs` | 478 | −322 |
| `test/fixtures/` excluded in `.credo.exs` | **474** | −4 |

`mix credo --strict` now: **474 findings** across 305 files, 68 checks.
By category: 296 Refactoring, 150 Readability, 27 Warning, 1 Software Design.

## FIX-LATER backlog — 474 findings by check

Worklist for any future Credo-cleanup effort. None blocks CI wiring decisions
(Phase 3); CI gating of these is a separate call.

| Check | Count | Category | Nature |
|-------|------:|----------|--------|
| `Refactor.Nesting` | 154 | Refactoring | functions nested deeper than 2 |
| `Readability.MaxLineLength` | 82 | Readability | lines > 100 chars |
| `Refactor.CyclomaticComplexity` | 66 | Refactoring | functions over complexity 9 |
| `Refactor.MapJoin` | 51 | Refactoring | `map |> join` → `map_join` — mechanical |
| `Readability.AliasOrder` | 33 | Readability | alias groups not sorted — mechanical |
| `Warning.ExpensiveEmptyEnumCheck` | 27 | Warning | `length(x) == 0` → `x == []` (26 test, 1 lib) |
| `Readability.PreferImplicitTry` | 27 | Readability | explicit `try` → implicit |
| `Refactor.UnlessWithElse` | 7 | Refactoring | `unless` with `else` block |
| `Refactor.CondStatements` | 6 | Refactoring | `cond` with <2 real conditions |
| `Readability.StringSigils` | 5 | Readability | quote-heavy strings → sigil |
| `Refactor.RejectReject` | 5 | Refactoring | chained `Enum.reject` |
| `Refactor.Apply` | 5 | Refactoring | `apply` with known arity |
| `Refactor.WithClauses` (redundant last clause) | 2 | Refactoring | `with` last clause redundant |
| `Readability.WithClauses` (single `<-` + else) | 2 | Readability | single-clause `with` → `case` |
| `Design.TagTODO` | 1 | Software Design | `project_context.ex:462` TODO comment |
| `Readability.LargeNumbers` | 1 | Readability | number needs `_` separators |
| **Total** | **474** | | |

## P2a status

- FIX-NOW: 0 — nothing blocked.
- IGNORE: `test/fixtures/` excluded — applied in `.credo.exs`.
- `Design.AliasUsage`: disabled — applied in `.credo.exs` (deliberate decision).
- `Consistency.LineEndings`: resolved by `.gitattributes` (commit `dda4217`).
- FIX-LATER: 474 — backlogged above.
- Sobelow and Dialyzer **not touched** — Phases 2b / 2c.
