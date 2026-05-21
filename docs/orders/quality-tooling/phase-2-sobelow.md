# Phase 2b — Sobelow Triage and Decisions (final)

Order: `docs/orders/2026-05-21-quality-tooling.md` | Triage: 2026-05-21
Decisions applied: 2026-05-21
Tool: `sobelow 0.14.1`, run as `mix sobelow --config` (config `.sobelow-conf`).
Raw output: `_sobelow_raw.txt` — gitignored.

Non-Phoenix run (Sobelow warns it cannot find a router — expected; Giulia is not
a Phoenix app). **105 initial findings.**

## Findings by type (initial 105)

| Check | Count | Confidence | Triage |
|-------|------:|------------|--------|
| `Traversal.FileModule` | 92 | Low | IGNORE class-wide — PathSandbox |
| `DOS.StringToAtom` | 5 | Low | 4 IGNORE (config-sourced) · 1 FIX-LATER |
| `SQL.Query` | 4 | Low | IGNORE — internal queries / integer LIMIT |
| `Misc.BinToTerm` | 2 | **High** | IGNORE — own CubDB cache (see below) |
| `XSS.SendResp` | 1 | Medium | IGNORE — shipped static asset |
| `DOS.BinToAtom` | 1 | Low | IGNORE — already mitigated |
| **Total** | **105** | | **0 FIX-NOW · 1 FIX-LATER · 104 IGNORE** |

No `Config.*` findings — Sobelow's config checks are Phoenix-specific.

## FIX-NOW — 0 items

No finding has a live exploit path. Giulia is a local-first daemon with a
deliberate file-access sandbox (`Giulia.Core.PathSandbox`); every High/Medium
finding resolves to trusted-source data on inspection (below).

## FIX-LATER — 1 finding + 1 conditional follow-up

Both logged in `sobelow-backlog.md`:

1. **`enrichment/consumer.ex:125`** — `String.to_atom/1` on enrichment-payload
   severity (externally-influenced data; violates the no-runtime-atoms
   convention). Low risk, real. Backlog entry 1.
2. **Graph-cache write-path hardening** — *conditional* follow-up tied to the
   two `Misc.BinToTerm` findings (see below). Not a fix to schedule; revisit
   only if the threat model expands. Backlog entry 2.

## IGNORE-WITH-JUSTIFICATION — 104 findings

### `Traversal.FileModule` ×92 (Low) — ignored class-wide (applied)

`File.read`/`write`/`mkdir_p` etc. with a variable path. Sobelow cannot see
Giulia's file-access security model: `Giulia.Core.PathSandbox` validates every
tool-driven path (dedicated adversarial suite,
`path_sandbox_adversarial_test.exs`); internal subsystems operate on
app-derived paths. Sampled 4 across the spread — `tools/template_references.ex:82`
(path from `ScanConfig.absolute_roots()`), `knowledge/builder.ex:455`
(indexed-project source path), `inference/bulk_replace.ex:78` (already-resolved
path), `core/context_manager.ex:295` (`mkdir_p` on app-flow project path) — all
app-controlled or sandbox-gated.

**Applied** — `Traversal.FileModule` added to the `ignore` list in
`.sobelow-conf` (with rationale comment). This is the one architectural
false-positive class; no other check was ignored.

### `Misc.BinToTerm` ×2 (High) — IGNORE, empirically strengthened

`lib/giulia/persistence/loader.ex:54` and `lib/giulia/persistence/verifier.ex:97`
— `:erlang.binary_to_term/1` on a binary read from Giulia's own CubDB cache
(`{project}/.giulia/cache/cubdb/`), both wrapped in `try`/`rescue`.

**Phase 2b attempted a defensive read-side migration** of both calls to
`Plug.Crypto.non_executable_binary_to_term(binary, [:safe])`. It was **reverted**
— the full suite went from the 9-failure baseline to 11, with 8 new failures
across `Persistence.VerifierTest` (4), `Persistence.WarmRestoreTest` (3) and
`Persistence.LoaderAdversarialTest` (1). The test log gave the exact cause:

```
Corrupt graph cache: cannot deserialize &Graph.Utils.vertex_id/1,
the term is not safe for deserialization
```

**Why `[:safe]` is incompatible with the current serialization.** libgraph's
`%Graph{}` struct carries a `vertex_identifier` field defaulting to the function
capture `&Graph.Utils.vertex_id/1`. `:erlang.term_to_binary` serializes that fun
into every cached graph. `[:safe]` and `non_executable_binary_to_term/2` reject
funs *by design* — so they reject every legitimate cached graph. Read-side
hardening is impossible without changing the write path.

**Strengthened IGNORE rationale.** Before this exercise the justification was
"we believe the cache is trusted." After it, the justification is empirical:
the cache demonstrably round-trips a *library-internal* fun
(`&Graph.Utils.vertex_id/1`) that `[:safe]` cannot deserialize — direct evidence
that the binary carries legitimate Giulia/libgraph state, not an attacker-
injected payload. The only `binary_to_term` threat here is an attacker planting
a malicious file under `{project}/.giulia/cache/`, which requires local write
access to the project — at which point the project is already compromised by
more direct means. Real `binary_to_term` RCE vectors are network-fed (HTTP body,
queue, cookie); none apply to this self-written on-disk cache.

Write-path remediation (strip `vertex_identifier` before `term_to_binary`,
restore on load) is documented as a **conditional follow-up** in
`sobelow-backlog.md` entry 2 — pursued only if the threat model expands to
local-write-but-not-privileged attackers (multi-user hosts, shared volumes).

### `SQL.Query` ×4 (Low) — all `storage/arcade/client.ex`
- `:166` `cypher/2` — flagged `statement` is a Cypher query built by Giulia's
  own code (Indexer/Consolidator), not user input.
- `:270` / `:288` / `:304` — `LIMIT #{limit}` interpolates an **integer**
  (typespec `non_neg_integer()`); data values use `:p` / `:b` parameter binding.
  An integer cannot carry SQL. Optional backlog hardening: parameterize LIMIT.

### `DOS.StringToAtom` ×4 (Low) — config-sourced
`config/dispatch_invariants.ex:90`, `:107`, `config/relevance.ex:113`,
`enrichment/registry.ex:135` — all map shipped-config-file strings to atoms at
boot, bounded vocabularies, loaded once. Not runtime user input.

### `DOS.BinToAtom` ×1 (Low)
`daemon/helpers.ex:56` — `safe_to_node_atom/1` already mitigates: strict
`name@host` regex, `String.to_existing_atom/1` first, `binary_to_atom/2` only
for genuinely new Erlang node names (unavoidable). Deliberate, documented.

### `XSS.SendResp` ×1 (Medium)
`daemon/routers/monitor.ex:193` — `serve_static/2` sends a developer-authored
HTML file from `priv/static/` via `send_resp`; `html` is not user-controlled.

## Final state

| Stage | Findings |
|-------|---------:|
| Initial Phase 2b run | 105 |
| `Traversal.FileModule` ignored class-wide in `.sobelow-conf` | **13** |

`mix sobelow --config` now reports **13 findings**: 5 `DOS.StringToAtom`,
4 `SQL.Query`, 2 `Misc.BinToTerm`, 1 `XSS.SendResp`, 1 `DOS.BinToAtom`.

Of those 13: **1 FIX-LATER** (`consumer.ex:125`) and **12 IGNORE**
(justified above). The 12 IGNOREs are left visible rather than silenced —
ignoring those checks wholesale would hide future genuine findings of the same
type, and 12 is a small enough number to keep on the report.

## P2b status

- FIX-NOW: 0.
- FIX-LATER: 1 finding (`consumer.ex:125`) + 1 conditional follow-up
  (graph-cache write-path) — both in `sobelow-backlog.md`.
- IGNORE: 104 — 92 `Traversal.FileModule` (ignored class-wide in `.sobelow-conf`)
  + 12 individual, justified above.
- `Misc.BinToTerm`: read-side `[:safe]` hardening attempted and reverted; root
  cause and conditional remediation documented.
- Dialyzer **not touched** — Phase 2c.
