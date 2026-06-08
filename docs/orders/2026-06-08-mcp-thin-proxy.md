# Order: MCP thin-proxy fix (param contract)

**Date:** 2026-06-08
**Status:** commit 1 (buckets 1+2) landed; facade (bucket 3) pending

## Diagnosis

REST and MCP both front the same internal handlers (`Giulia.Knowledge.Store`),
but the param contract was re-implemented per protocol instead of shared. The
MCP brief was a THIN PROXY — forward to the shared layer. It wasn't: REST's
coercion lives inside Plug route-macro bodies (not callable), so MCP dispatch
re-implemented required-ness/defaults/coercion in a parallel helper set. Store
(typed, pure) being the only shared point is what prevented real divergence;
the gates in front (required-ness, defaults, enum advertisement) were
triplicated and could drift independently — the v0.3.7 divergence class.

Store stays exactly as-is: typed positional args + semantic validation +
`{:unknown_action}`/`{:not_found}` backstop. It must NOT learn about
`args["depth"]`, string input, or HTTP defaults. The facade holds the protocol
edge once: path resolution + string→typed coercion + defaults → then Store.
`@skill` `values:`/`default:` maps are discovery advertisement — untouched.

## Sequence

1. **Commit 1 (buckets 1+2) — deletion, no facade.** DONE.
   - Bucket 1 (Store already validates): `dependents`, `centrality`,
     `pre_impact_check`, `dependencies` — delete redundant MCP `require_param`,
     forward to Store. Verify each hits the `has_vertex?`→`{:not_found}` (or
     `{:unknown_action}`) backstop before deleting; nil-safe required.
   - Bucket 2: `parse_suppress` deduped into `Giulia.Daemon.Helpers`.
2. **Facade (bucket 3).** Path-resolution parity verify FIRST (REST
   `resolve_and_check_ready` vs MCP `require_path` — preserve any readiness step
   explicitly). Build on `impact` only, review the shape, then replicate to
   `style_oracle`/search, `unprotected_hubs`, `duplicates`.
3. Fold `schema_version` stamp (pre_impact_check) + error-tuple→message mapping
   into the facade's shared response path. The parity marker flips green when
   the stamp lands.

## Testing rule (STANDARD — do not let it recur)

**Run the full `test/giulia/mcp/` dir per commit — never only the file just
touched.** The per-endpoint-only check is the default failure mode: the three
bucket-1 commits each left `required_params_test.exs` red (it pinned the deleted
gate's exact message) because only the new parity file was run per-endpoint. The
full-dir run caught it. This is not a one-off — it's the recurring trap. Full
MCP dir green is the gate on every commit in this order.

Decisions on record: REST keeps its 400-at-the-edge gate (edge validation stays
at the edge, not pushed into Store). `@skill` maps are advertisement, not
enforcement. Don't rebuild `:4000` until the whole thing is green.
