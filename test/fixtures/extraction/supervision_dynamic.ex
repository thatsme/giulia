# Supervision shape: DYNAMIC
#
# Two DynamicSupervisors declared the two ways they occur in practice: as an
# inline `{DynamicSupervisor, name: X}` child spec, and as a direct
# `DynamicSupervisor.start_link/1` call in a wrapper module.
#
# Both share one module, so module identity would collapse them into a single
# vertex — they must stay distinct, keyed by registered name. Neither carries
# child edges: their children are started at runtime via `start_child/2`, so an
# empty child list here is CORRECT, not an unresolved one.
defmodule Fixture.Dynamic.Application do
  use Application

  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Fixture.Dynamic.WorkerSup},
      {DynamicSupervisor, strategy: :one_for_one, name: Fixture.Dynamic.SessionSup},
      Fixture.Dynamic.Manager
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Fixture.Dynamic.Supervisor)
  end
end

defmodule Fixture.Dynamic.Standalone do
  def start_link(_arg) do
    DynamicSupervisor.start_link(strategy: :one_for_one, name: Fixture.Dynamic.Standalone)
  end
end
