# Supervision shape: UNRESOLVABLE (the honest-gap case)
#
# Three child lists that sit outside the bounded binding resolution. Each must
# yield `children_unresolved: true` with NO child edges — never a partial list
# presented as complete, because every downstream check reasons over this tree
# and a silent omission becomes a false negative.
#
#   - built by a function call
#   - built by `Enum.map/2`
#   - bound in a different function (resolution never crosses that boundary)
#
# The multiply-assigned variable is the fourth case: two assignments to one name
# means the binding is dropped rather than one of them guessed at.
defmodule Fixture.Unresolvable.FromFunction do
  def start(_type, _args) do
    Supervisor.start_link(build_children(),
      strategy: :one_for_one,
      name: Fixture.Unresolvable.FromFunction
    )
  end

  defp build_children, do: [Fixture.Unresolvable.Hidden]
end

defmodule Fixture.Unresolvable.FromEnum do
  def start(_type, _args) do
    children = Enum.map(worker_ids(), fn id -> {Fixture.Unresolvable.Worker, id: id} end)

    Supervisor.start_link(children, strategy: :one_for_one, name: Fixture.Unresolvable.FromEnum)
  end

  defp worker_ids, do: [1, 2, 3]
end

defmodule Fixture.Unresolvable.Reassigned do
  def start(_type, _args) do
    children = [Fixture.Unresolvable.First]
    children = [Fixture.Unresolvable.Second]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fixture.Unresolvable.Reassigned
    )
  end
end
