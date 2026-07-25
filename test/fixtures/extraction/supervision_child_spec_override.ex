# Supervision shape: CHILD_SPEC OVERRIDE
#
# The two explicit child-spec forms, both of which carry a restart policy that
# a bare alias cannot express:
#
#   - `Supervisor.child_spec(child, restart: :temporary)` — the override must
#     reach the child, not be dropped with the wrapper.
#   - `%{id:, start: {M, :start_link, []}, restart: :transient}` — the module
#     comes from the `start` MFA, which the AST represents as
#     `{:{}, meta, [mod, fun, args]}` because three-element tuples are not
#     literal. Reading it as a plain tuple yields `:{}` as the module.
#
# A bare alias is included as the control: restart :unknown, since none stated.
defmodule Fixture.Override.Application do
  use Application

  def start(_type, _args) do
    children = [
      Fixture.Override.Plain,
      Supervisor.child_spec({Fixture.Override.Temporary, []}, restart: :temporary),
      %{
        id: Fixture.Override.Mapped,
        start: {Fixture.Override.Mapped, :start_link, []},
        restart: :transient
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Fixture.Override.Supervisor)
  end
end
