# Giulia Configuration Reference

This document is the canonical reference for every tunable in `priv/config/`. Three JSON files control behaviour that should be tunable without recompilation:

- [`scoring.json`](#scoringjson) — heatmap, change_risk, god_modules, unprotected_hubs scoring constants
- [`dispatch_patterns.json`](#dispatch_patternsjson) — runtime-dispatch patterns the AST walker can't statically see
- [`scan_defaults.json`](#scan_defaultsjson) — universal source-root list for Mix projects

All three are loaded once at daemon startup, cached in `:persistent_term` for free reads, and tracked by `Knowledge.CodeDigest` so edits invalidate the L2 cache automatically.

## Overview

### Loading

Each config file has a dedicated loader module that mirrors the same pattern:

| File | Loader |
|---|---|
| `scoring.json` | `Giulia.Knowledge.ScoringConfig` |
| `dispatch_patterns.json` | `Giulia.Knowledge.DispatchPatterns` |
| `scan_defaults.json` | `Giulia.Context.ScanConfig` |

On first call, the loader reads the JSON, parses with atom keys, and caches the result in `:persistent_term`. Subsequent reads are free. None of the loaders watch the file for changes — pick up edits with a daemon restart.

### Cache invalidation contract

`Knowledge.CodeDigest` hashes the **content** of all three config files alongside the BEAM md5s of the four code-tier modules (`Builder`, `Metrics`, `Behaviours`, `DispatchPatterns`). The persisted L2 caches (graph + metrics) are tagged with the digest at write time. On daemon startup, warm-restore compares stored vs current digest:

- Match → load cache as-is
- Mismatch → log `"Code digest changed (X -> Y) — invalidating … cache"`, drop the cache, force a rebuild on next scan

So the **operator workflow** for tuning any config is:

1. Edit the JSON
2. Restart the daemon (`docker compose restart giulia-worker`)
3. Trigger a scan or wait for the next warm-restore — caches will rebuild with the new values automatically

The AST cache is **not** invalidated by config edits — only graph + metric caches. AST extraction is the expensive step (~10s on 580+ files) and shouldn't run on every config tweak. If a config edit needs full re-extraction (rare), use `?force=true` on `/api/index/scan`.

---

## `scoring.json`

Scoring constants for the four metric families. Defaults are calibrated for typical Elixir application/library shapes and must remain valid for every codebase per the universal-defaults principle (no per-project override file).

### `heatmap` — module health score (0–100)

The composite score is a weighted sum of four normalized factors. Each factor is normalized to 0–100 by dividing by its cap (saturated at 100), then weighted, then summed and truncated.

```
score = trunc(
  norm_centrality * weights.centrality +
  norm_complexity * weights.complexity +
  norm_test       * weights.test_coverage +
  norm_coupling   * weights.coupling
)
```

#### `heatmap.weights`

How each factor contributes to the composite. **Should sum to 1.0.**

| Field | Default | Meaning |
|---|---|---|
| `centrality` | 0.30 | How much fan-in (incoming module-level edges) drives the score |
| `complexity` | 0.25 | How much AST complexity (control-flow node count) drives the score |
| `test_coverage` | 0.25 | How much missing tests drives the score (penalty when `has_test = false`) |
| `coupling` | 0.20 | How much max coupling to any single peer drives the score |

#### `heatmap.normalization`

Saturation caps. Values above the cap don't increase the factor — every cap value is treated as "this is already worst-case."

| Field | Default | Meaning |
|---|---|---|
| `centrality_cap` | 15 | In-degree at which centrality factor saturates at 100. Increase for very large codebases where 15 dependents isn't unusual |
| `complexity_cap` | 200 | Module-level AST complexity at which the factor saturates. Increase for codebases with intentionally large modules |
| `coupling_cap` | 50 | Max call-count to a single peer at which the factor saturates |
| `missing_test_factor` | 100 | Raw factor value when `has_test = false`. With the default 0.25 test-coverage weight, this contributes +25 to the score |

#### `heatmap.zones`

Score thresholds for the red/yellow/green classification.

| Field | Default | Meaning |
|---|---|---|
| `red_min` | 60 | Score at or above this is red zone |
| `yellow_min` | 30 | Score at or above this (but below `red_min`) is yellow zone |

Below `yellow_min` is green.

### `change_risk` — modify-blast-radius score

Multiplicative composite score. The base captures intrinsic complexity + outward dependency surface; the multiplier amplifies by inward dependency count.

```
api_penalty = trunc(api_ratio * total_funcs)
base =
  (complexity     * weights.complexity) +
  (fan_out        * weights.fan_out) +
  (max_coupling   * weights.max_coupling) +
  api_penalty +
  (total_funcs    * weights.total_funcs)
multiplier = 1 + (centrality / centrality_divisor)
score = trunc(base * multiplier)
```

#### `change_risk.weights`

| Field | Default | Meaning |
|---|---|---|
| `complexity` | 2 | Coefficient on AST complexity in base |
| `fan_out` | 2 | Coefficient on outgoing dependency count |
| `max_coupling` | 2 | Coefficient on max calls to any single peer |
| `total_funcs` | 1 | Coefficient on total function count (def + defp) |

#### `change_risk.centrality_divisor`

| Field | Default | Meaning |
|---|---|---|
| `centrality_divisor` | 2 | Divides centrality (in-degree) when computing multiplier. A value of 2 means each incoming dependent adds 50% to the base score |

#### `change_risk.top_n`

| Field | Default | Meaning |
|---|---|---|
| `top_n` | 20 | Number of top-scored modules to return from the endpoint |

### `god_modules` — broad module detection

Additive score weighted by three factors. No multiplicative term — large breadth alone is enough.

```
score =
  (func_count   * weights.func_count) +
  (complexity   * weights.complexity) +
  (centrality   * weights.centrality)
```

#### `god_modules.weights`

| Field | Default | Meaning |
|---|---|---|
| `func_count` | 1 | Coefficient on total function count |
| `complexity` | 2 | Coefficient on AST complexity |
| `centrality` | 3 | Coefficient on in-degree (heaviest weight — a god module with many dependents is the highest-priority refactor target) |

#### `god_modules.top_n`

| Field | Default | Meaning |
|---|---|---|
| `top_n` | 20 | Number of top-scored modules to return |

### `unprotected_hubs` — hub modules with low protection

A "hub" is a module with sufficient in-degree to make low spec/doc coverage risky.

#### `unprotected_hubs.default_hub_threshold`

| Field | Default | Meaning |
|---|---|---|
| `default_hub_threshold` | 3 | Minimum in-degree to qualify as a hub. Overridable per-call via `?hub_threshold=N` |

#### `unprotected_hubs.spec_thresholds`

| Field | Default | Meaning |
|---|---|---|
| `red_max` | 0.5 | Modules with `spec_count / public_count` below this are red severity |
| `yellow_max` | 0.8 | Modules between `red_max` and `yellow_max` are yellow severity. Above is green and excluded from the report |

---

## `dispatch_patterns.json`

Runtime-dispatch patterns that AST analysis can't statically see. Consumed by `Giulia.Knowledge.DispatchPatterns` at startup. Used by `dead_code` to exempt functions that look unreachable in source but ARE called via runtime mechanisms.

### Pattern types

Three types are currently supported.

#### `text_match`

File-content regex match. For dispatch patterns living outside the AST graph (e.g., shell scripts).

| Field | Meaning |
|---|---|
| `id` | Stable identifier for logs and reporting |
| `type` | Always `"text_match"` |
| `description` | Free-text rationale |
| `file_glob` | Glob pattern (relative to project root) of files to scan |
| `call_regex` | Regex with capture groups; non-matching files are skipped |
| `arity` | Arity to assume for the matched function (no AST to count from) |
| `capture` | `{module: <group_index>, function: <group_index>}` mapping the regex captures |

Example: Mix Release shell overlays.

```json
{
  "id": "mix_release_overlays",
  "type": "text_match",
  "description": "Mix Release overlay shell scripts invoke Elixir functions via `<app> eval Module.function`. Callers live outside the AST graph (shell is not Elixir).",
  "file_glob": "rel/overlays/*.sh",
  "call_regex": "eval\\s+([A-Z][A-Za-z0-9_.]+)\\.([a-z_][A-Za-z0-9_?!]*)\\s*$",
  "arity": 0,
  "capture": { "module": 1, "function": 2 }
}
```

#### `use_based_function_regex`

Find modules that `use` one of a list of behaviours and exempt their functions matching a name regex. Universal naming-convention dispatch.

| Field | Meaning |
|---|---|
| `id` | Stable identifier |
| `type` | Always `"use_based_function_regex"` |
| `description` | Free-text rationale |
| `behaviours` | List of module-name strings — modules that `use` any of these qualify |
| `function_regex` | Regex matched against function names |
| `arity` | Arity required to match (functions of other arities are not exempted) |

Example: ExMachina factories.

```json
{
  "id": "ex_machina_factories",
  "type": "use_based_function_regex",
  "description": "ExMachina testing factories — modules that `use ExMachina` expose `<name>_factory/0` functions invoked via runtime name-dispatch.",
  "behaviours": ["ExMachina", "ExMachina.Ecto"],
  "function_regex": "^[a-z_][A-Za-z0-9_]*_factory$",
  "arity": 0
}
```

#### `meta_macro_using_apply`

AST-level detection of the `defmacro __using__/1 do quote do: apply(__MODULE__, arg, []) end end` idiom. Universal across Phoenix-style helper modules — `mix phx.new` generates this pattern in `MyAppWeb`.

| Field | Meaning |
|---|---|
| `id` | Stable identifier |
| `type` | Always `"meta_macro_using_apply"` |
| `description` | Free-text rationale |
| `enabled` | `true`/`false` toggle (use to disable temporarily without removing the entry) |

The mechanism has no other tunables — detection is purely structural.

```json
{
  "id": "elixir_meta_macro_using_apply",
  "type": "meta_macro_using_apply",
  "description": "The Phoenix-style `use MyAppWeb, :shape` idiom: defmacro __using__(arg) do apply(__MODULE__, arg, []) end. Every `use Mod, :shape` caller invokes Mod.shape/0 at compile time but the call is inside the macro's quoted body.",
  "enabled": true
}
```

### Adding a new pattern

1. Edit `dispatch_patterns.json` — add a new entry to the `patterns` array.
2. Restart the daemon. CodeDigest detects the change and invalidates L2 metric caches.
3. Trigger a scan (or wait for warm-restore + first metric query).

If the pattern requires a NEW pattern type (not one of the three above), code changes in `Knowledge.DispatchPatterns` are required. Only the existing three types are runtime-loadable from JSON.

---

## `scan_defaults.json`

Source-root list for Mix projects. Walked by the indexer to collect Elixir source files for AST extraction.

### `source_roots`

A list. Entries may be directories (walked recursively for `*.ex` and `*.exs`) or individual files.

```json
"source_roots": [
  "lib",
  "test/support",
  "test/test_helper.exs"
]
```

| Default entry | Rationale |
|---|---|
| `lib` | Universal Mix convention — every project has it |
| `test/support` | ExUnit convention for shared test helpers; modules here are typically called by every test |
| `test/test_helper.exs` | Universal ExUnit bootstrap; setup hooks here exercise project code at compile time |

Missing paths are skipped silently — a project without `test/support` doesn't error.

### Mix-aware extension

In addition to `source_roots`, the indexer parses the target project's `mix.exs` for `def/defp elixirc_paths` clauses and unions all string literals across them with the configured `source_roots`. This catches project-declared non-standard compile dirs (e.g., Plausible's `extra/lib`) without per-codebase opt-in.

The mechanism is in `Giulia.Context.ScanConfig.mix_exs_roots/1` — entirely automatic, no JSON tuning required.

### Adding a new universal default

If you find that another path is a universal Elixir project convention (e.g., a future common test layout), add it to `source_roots`. Per the universal-defaults principle, only add entries that are valid for **every** Mix project — don't add entries that only apply to a specific codebase.

---

## Operator quick reference

| Symptom | Where to look |
|---|---|
| Heatmap reports too many red modules | `scoring.json` → `heatmap.zones.red_min` (raise) or `heatmap.weights.test_coverage` (lower) |
| Change_risk top-10 is dominated by tiny modules | `scoring.json` → `change_risk.weights.complexity` or `centrality_divisor` |
| God_modules list ignores high-fan-in modules | `scoring.json` → `god_modules.weights.centrality` (raise) |
| Public function called via runtime mechanism flagged dead | Add a `dispatch_patterns.json` entry |
| Mix-style project lays code in non-`lib/` dir | Usually auto-detected via `mix.exs`; otherwise add to `scan_defaults.json` source_roots |

For changes that should affect cached metrics: edit JSON → restart daemon → trigger a scan or wait for the next metric warming.
