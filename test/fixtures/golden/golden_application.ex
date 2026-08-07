# Pass 8 (behaviour dispatch): `use Application` + start/2 defined
#   => Application -> Golden.Application.start/2 {:calls, :behaviour_impl}
# Pass 6 (references): children list module atom
#   => Golden.Application -> Golden.Server :references
# Pass 12 (supervision): anonymous Supervisor.start_link — no `name:`, so the
# enclosing module is the process identity; `children` resolves through a
# single-assignment binding to a literal list
#   => Golden.Application -> Golden.Server {:supervises, %{order: 0,
#      restart: :unknown, strategy: "one_for_one", conditional: false}}
#   restart is :unknown because a bare alias child spec states none.
# NOT edges: `use Application` produces no :depends_on/:implements
# (external module, membership-gated). Note Pass 12 does NOT emit a vertex for
# `Supervisor` itself — it is loadable stdlib, not a project module, and the
# supervisor's identity is Golden.Application.
defmodule Golden.Application do
  use Application

  def start(_type, _args) do
    children = [Golden.Server]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
