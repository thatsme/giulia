# Supervision shape: FLAT
#
# One named supervisor, literal child list, the two most common child-spec
# forms (bare alias and `{module, opts}`), and a child whose `name:` differs
# from its module — the identity rule must key that child by the name.
defmodule Fixture.Flat.Application do
  use Application

  def start(_type, _args) do
    children = [
      Fixture.Flat.Cache,
      {Fixture.Flat.Worker, pool_size: 4},
      {Registry, keys: :unique, name: Fixture.Flat.Registry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Fixture.Flat.Supervisor)
  end
end
