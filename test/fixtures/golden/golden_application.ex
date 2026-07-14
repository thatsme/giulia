# Pass 8 (behaviour dispatch): `use Application` + start/2 defined
#   => Application -> Golden.Application.start/2 {:calls, :behaviour_impl}
# Pass 6 (references): children list module atom
#   => Golden.Application -> Golden.Server :references
# NOT edges: `use Application` produces no :depends_on/:implements
# (external module, membership-gated); bare Supervisor.start_link
# produces nothing (Supervisor is loadable stdlib, not a project module).
defmodule Golden.Application do
  use Application

  def start(_type, _args) do
    children = [Golden.Server]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
