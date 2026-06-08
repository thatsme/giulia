# Order: `@skill` params-map backfill

**Date:** 2026-06-08
**Build at start:** 162
**Status:** backfill complete — 78 of 78 blocks on the map format. Remaining
close-out: Step 78 (SKILL.md shrink) below.

## Goal

Migrate every `@skill` annotation's `params` from bare `:required`/`:optional`
atoms to the structured map format, so each endpoint's real contract (enums,
defaults, query-vs-body, preconditions) lives next to the route instead of in a
hand-maintained `SKILL.md` that drifts. End state: `SKILL.md` shrinks back to
bootstrap + discovery pattern (Build 98 intent).

## The format (single source of truth)

Defined in `Giulia.Daemon.SkillRouter`'s moduledoc. Each param value is a map:

```elixir
relevance: %{
  required: false,
  in: "query",                 # "query" | "body"
  values: ~w(high medium all),  # optional — emitted to MCP JSON Schema as `enum`
  default: "all",               # optional — WIRE form (string); folded into the
                                #   MCP description because Anubis 1.0.0 drops it
  doc: "..."                    # optional — short prose
}
```

Top-level `notes:` (optional, freeform) carries preconditions / 422 conditions /
runtime caveats. `returns:` stays prose — response shape lives in the dispatched
handler's `@spec`, not duplicated here.

Proven end-to-end (unit + Anubis `to_json_schema/1` integration round-trip) in
`test/giulia/mcp/tool_schema_test.exs`. The tuple form, `enum` emission,
`required` preservation, and `default`-fold are verified against deps source —
**no need to re-run the integration nail per block.** `mix compile` +
`mix test test/giulia/mcp/` before each commit lands is sufficient.

## Scope: 76 remaining blocks

Per-router counts (`__skills__/0`): approval 2, discovery 4, index 10,
intelligence 6, knowledge 27 (− 2 done = 25), monitor 7, runtime 16, search 3,
transaction 3. Total remaining: **76**.

Two tiers of work:

### Tier A — real enrichment (~18 blocks)

Endpoints carrying enums, defaults, body params, MFA formats, or documented
error/empty states. These recover the detail currently stranded in `SKILL.md`:

- **knowledge:** `conventions` (module, `suppress` grammar, `relevance` enum),
  `pre_impact_check` (`action` enum + `target`/`new_name` **body** params),
  `impact` (`depth` default), `logic_flow` + `path` (MFA `Module.func/arity`
  format), `style_oracle` (`q`, `top_k`), `unprotected_hubs`
  (`hub_threshold`/`spec_threshold` defaults), `struct_lifecycle` (`struct`
  optional), `centrality`/`dependents`/`dependencies` (`module` required).
- **index:** `scan` (body `path`, 422 conditions), `enrichment` ingest
  (`tool`/`project`/`payload_path` body, allowlist 422), `status` (`empty`
  state), `verify_l2` (`check` enum `graph|ast|metrics|all`), `compact`
  (`include: "arcade"`).
- **intelligence:** `enrichments` (`mfa` vs `module`, the two empty shapes),
  `preflight` + `briefing` (body / `prompt`).
- **runtime/search:** `top_processes` (`metric` enum), `hot_spots`
  (`path`/`node`), `connect` (body), `semantic` (`concept`/`top_k`), `search`
  (`q`).

Source the detail from the current `SKILL.md` table cells (the authoritative
content until it shrinks) and verify each against the route's actual arg
handling — do not transcribe blind.

### Tier B — mechanical format bump (~58 blocks)

Path-only / trivial endpoints. One-line conversion:

```elixir
params: %{path: :required}
# becomes
params: %{path: %{required: true, in: "query", doc: "Absolute project path"}}
```

No `notes`, no `values`, no `default`. These carry no lost detail —
`path: required -> JSON stats` is genuinely all there is to say.

## Execution order

1. One router at a time, lowest route-count first (approval → transaction →
   search → intelligence → monitor → index → runtime → knowledge). Commit
   per-router (or per logical group) with `mix test test/giulia/mcp/` green.
2. Tier B bumps and Tier A enrichment can ride the same per-router commit.
3. Keep the legacy atom/binary clauses in `ToolSchema`
   (`required?`/`param_description`) as a **permanent guard** — NOT a
   coexistence path to delete. Although all 78 blocks are maps, removing the
   atom clauses would let a future param written with muscle-memory
   `:required` fall through to `required?(_) -> false` and silently lose its
   required-ness in the MCP schema. The `build_input_schema/1`
   build-accountability test keeps the guard honest. (Original plan said
   "remove as dead code"; superseded — they are a guard, not dead code.)

## Step 78 — SKILL.md shrink (DO NOT SKIP)

**When the 78th block lands**, shrink `SKILL.md` (and `docs/SKILL.md`) to the
bootstrap + discovery pattern only — health check, discovery-first instructions,
the `__skills__/0` / `/api/discovery/*` usage — targeting ~80 lines (Build 98
intent). The per-endpoint param/enum/default detail now lives in the `@skill`
maps and is served by Discovery; the markdown tables become redundant and must
be deleted, not left to rot. Reconcile the two repo copies (`SKILL.md` vs
`docs/SKILL.md`) into one in the same pass.

This step is recorded here, not in anyone's head — it is the close-out condition
for this order.
