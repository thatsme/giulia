# Sobelow — FIX-LATER Backlog

Items surfaced by the Phase 2b Sobelow triage and deferred. See
`phase-2-sobelow.md` for the full triage.

## 1. `String.to_atom/1` on enrichment-payload severity

- **Location:** `lib/giulia/enrichment/consumer.ex:125`
- **Finding:** `DOS.StringToAtom` (Low confidence)
- **Code:**

  ```elixir
  defp normalize_severity(s) when is_atom(s), do: s
  defp normalize_severity(s) when is_binary(s), do: String.to_atom(s)
  defp normalize_severity(_), do: :info
  ```

- **Risk:** the severity string originates from ingested enrichment payloads
  (external analysis-tool output). `String.to_atom/1` on externally-influenced
  data can exhaust the atom table — atoms are never garbage-collected — if an
  enrichment source feeds unbounded distinct severity strings. This also
  violates the project convention in `.claude/rules/coding-conventions.md`
  ("Never create atoms from runtime strings"). Severity is in practice a small
  vocabulary, so real-world risk is low — but the code does not enforce that.
- **Proposed fix:** switch to `String.to_existing_atom/1` wrapped in a `rescue`
  that falls back to `:info`, or an explicit allowlist mapping of the known
  severity strings to atoms.

## 2. Optional graph-cache write-path hardening (conditional)

- **Date logged:** 2026-05-21
- **Related findings:** `Misc.BinToTerm` (High confidence) at
  `lib/giulia/persistence/loader.ex:54` and
  `lib/giulia/persistence/verifier.ex:97`.
- **Context:** Phase 2b attempted a defensive read-side migration of both
  `:erlang.binary_to_term/1` calls to a non-executable / `[:safe]`
  deserialization. It was reverted — 8 tests failed. Root cause: libgraph's
  `%Graph{}` struct carries a `vertex_identifier` field defaulting to the
  function capture `&Graph.Utils.vertex_id/1`, which `:erlang.term_to_binary`
  serializes into every cached graph. `[:safe]` /
  `Plug.Crypto.non_executable_binary_to_term/2` reject funs by design, so they
  reject every legitimate cached graph. Read-side hardening is therefore
  impossible without changing the write path.
- **Why deferred (not pursued in Phase 2b):** the only `binary_to_term` threat
  here is an attacker planting a malicious cache file under
  `{project}/.giulia/cache/`. That requires local write access to the project's
  cache subtree — an attacker with that access already controls the project
  directory. Real `binary_to_term` RCE vectors are network-fed (HTTP body,
  message queue, cookie); none apply to this on-disk, self-written cache. The
  hardening is marginal defense-in-depth, not a vulnerability fix.
- **Proposed fix (if pursued):** on the write path, strip `vertex_identifier`
  to `nil` before `term_to_binary` and restore the default on load, so the
  cached binary contains no fun — then `[:safe]` deserialization works on read.
- **Caveats for whoever picks this up:** non-trivial. Must handle libgraph
  version upgrades where the default `vertex_identifier` changes, any code path
  that sets a custom `vertex_identifier`, and a round-trip invariant check
  (the deserialized graph must behave identically). Each is a real test burden.
- **Trigger condition:** revisit only if the threat model expands to include
  local-write-but-not-otherwise-privileged attackers — multi-user hosts, shared
  cache volumes, untrusted co-tenants. Today it is marginal.
