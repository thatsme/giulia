# Supervision shape: CONDITIONAL (the tiered-children idiom)
#
# The shape Giulia's own application.ex uses. Children are built in separate
# single-assignment variables, some gated behind `if`/`case`, then concatenated
# with `++`. Extraction must yield the UNION with per-child conditionality:
#
#   - `base` children      → conditional: false (present in every branch)
#   - `optional` children  → conditional: true  (one branch is [])
#   - `mode` children      → conditional: true  (case clauses disagree)
#   - the appended child   → conditional: true  (outer if adds it in one branch)
#
# Conditionality must survive the OUTER union: `all` appears in both branches of
# the final `if`, so a union that recomputes flags from branch membership alone
# would wrongly report the inner tiers as unconditional.
defmodule Fixture.Conditional.Application do
  use Application

  def start(_type, _args) do
    base = [Fixture.Conditional.Core]

    optional =
      if enabled?() do
        [Fixture.Conditional.Optional]
      else
        []
      end

    mode =
      case role() do
        :primary -> [Fixture.Conditional.Primary]
        :replica -> [Fixture.Conditional.Replica]
      end

    all = base ++ optional ++ mode

    children =
      if test_env?() do
        all
      else
        all ++ [{Fixture.Conditional.Endpoint, port: 4000}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Fixture.Conditional.Supervisor)
  end

  defp enabled?, do: System.get_env("ENABLED") == "true"
  defp role, do: :primary
  defp test_env?, do: false
end
