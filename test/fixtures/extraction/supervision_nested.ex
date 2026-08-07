# Supervision shape: NESTED
#
# A root supervisor whose child is itself a supervisor, declared in a separate
# module via `Supervisor.init/2`. The child supervisor must appear both as a
# child of the root and as a supervisor in its own right, with its own children
# — one vertex, two roles.
defmodule Fixture.Nested.Application do
  use Application

  def start(_type, _args) do
    children = [
      Fixture.Nested.Telemetry,
      Fixture.Nested.SubTree
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Fixture.Nested.Supervisor)
  end
end

defmodule Fixture.Nested.SubTree do
  use Supervisor

  def init(_arg) do
    children = [
      Fixture.Nested.Leaf.One,
      Fixture.Nested.Leaf.Two
    ]

    Supervisor.init(children, strategy: :one_for_all, name: Fixture.Nested.SubTree)
  end
end
