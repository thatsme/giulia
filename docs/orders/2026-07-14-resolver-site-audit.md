# Resolver-Site Audit — Pass 6 Is the Only Prefix-Walk

**Date:** 2026-07-14
**Trigger:** the Pass 6 stdlib-alias fabrication fix (`resolve_with_fallback/4`
guard in `Knowledge.Builder`). Question raised in review: does any *other*
graph-builder pass carry its own namespace-prefix resolution — i.e. is the
fabrication bug patched at one of N sites, with a `:calls`-class instance
still live that the `cycles/1` `:references` filter would not catch?

## Verdict: no second site. Verified negative.

### Evidence

1. **Single chokepoint.** `resolve_with_fallback/4` and its companion
   `caller_namespace_prefixes/1` each have exactly one call site:
   Pass 6 `extract_module_references/3` (builder.ex). No other pass
   walks caller namespace prefixes.

2. **Pass 4 (function-call edges) resolves independently and safely.**
   `extract_calls_from_body/4` resolves remote calls through
   `resolve_module_parts/2` plus an explicit per-file `alias_map`, then
   gates on `MapSet.member?(all_modules, mod)` with **no fallback**.
   A bare stdlib alias (`Application.get_env/2`) yields `"Application"`,
   fails project-set membership, and produces no edge. The `via` labels
   (`:direct | :alias_resolved | :erlang_atom | :local`) record the
   resolution path — none is prefix-derived.

3. **Empirical cross-check.** Pre-fix, the 13 modules calling bare
   `Application.*` produced 13 fabricated `[references]` edges into
   `Giulia.Application` and **zero** `[calls]` edges — consistent with
   Pass 4 being membership-gated.

4. **The bare `Application` vertex is by-design Pass 8 output, not a
   fabrication.** `Giulia.Application` does `use Application`;
   `Application` is a known behaviour, so `add_behaviour_dispatch_edges/2`
   mints the behaviour vertex and synthesizes
   `Application -> Giulia.Application {:calls, :behaviour_impl}` —
   dispatch-edge synthesis pointing at the implementer. Direction is the
   discriminator: a fabricated caller-edge would run
   `caller -> *.Application`, not `behaviour -> implementer`.

## Invariant to preserve

Namespace-prefix fallback is allowed in exactly one place —
`Knowledge.Builder.resolve_with_fallback/4` — and only behind both guards:

1. direct project-set membership wins first (a project module literally
   named after a stdlib module still resolves by identity), and
2. names loadable in the analyzer's own runtime
   (`loadable_runtime_module?/1`) never fall through to the prefix walk.

Any future pass that needs short-form resolution must go through this
function, not grow its own walk. Regression tests:
`builder_test.exs` — "stdlib alias colliding with a project module does
not resolve via prefix fallback" / "project module literally named
Application still gets a direct :references edge".
