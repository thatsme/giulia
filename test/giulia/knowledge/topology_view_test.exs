defmodule Giulia.Knowledge.TopologyViewTest do
  @moduledoc """
  Regression cover for `Store.topology_view/1`, the endpoint behind the Graph
  Explorer (`GET /api/knowledge/topology`).

  It had no tests at all, which is how Builder Pass 12 took the whole Explorer
  down while 2338 tests stayed green: `topology_view/1` called `to_string/1` on
  every edge label, and the new `{:supervises, %{...}}` label raised
  `Protocol.UndefinedError` for Tuple. The route returned a bare HTTP 500 with
  an empty body, so the browser failed at `r.json()` with a parse error that
  named neither the endpoint nor the cause.
  """
  use ExUnit.Case, async: false

  alias Giulia.Knowledge.Store

  @knowledge_table :giulia_knowledge_graphs

  setup do
    project = "/test/topology_view_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ets.delete(@knowledge_table, {:graph, project}) end)
    %{project: project}
  end

  defp seed!(project, edges) do
    graph =
      Enum.reduce(edges, Graph.new(type: :directed), fn {from, to, label}, g ->
        g
        |> Graph.add_vertex(from, :module)
        |> Graph.add_vertex(to, :module)
        |> Graph.add_edge(from, to, label: label)
      end)

    :ets.insert(@knowledge_table, {{:graph, project}, graph})
    graph
  end

  test "renders every edge-label shape without raising", %{project: project} do
    # Passes 2 and 5-12 emit bare atoms, {atom, atom} tuples and {atom, map}
    # tuples. `all_dependencies_with_rollup/1` normalises the sub-labelled
    # tuples — `{:calls, :protocol_impl}` arrives here already rolled up to the
    # atom `:calls` — so the only tuple that ever reached this function was
    # `:supervises`. Rendering stays total anyway: the cost is three clauses,
    # and the failure mode it prevents is a bare 500 that takes the whole
    # Explorer down.
    seed!(project, [
      {"A", "B", :depends_on},
      {"B", "C", {:calls, :protocol_impl}},
      {"C", "D", {:supervises, %{restart: :unknown, order: 0, strategy: "one_for_one", conditional: false}}}
    ])

    assert {:ok, view} = Store.topology_view(project)

    labels = Enum.map(view.edges, & &1.data.label)
    assert "depends_on" in labels
    assert "calls" in labels
    assert Enum.all?(labels, &is_binary/1), "every rendered label must be a string"
  end

  test "supervision edges are excluded from the dependency view", %{project: project} do
    seed!(project, [
      {"A", "B", :depends_on},
      {"A", "B", {:supervises, %{restart: :permanent, order: 0, strategy: "one_for_one", conditional: false}}}
    ])

    assert {:ok, view} = Store.topology_view(project)

    refute Enum.any?(view.edges, fn e -> e.data.label =~ "supervises" end),
           "supervision edges are wiring, not dependency coupling — they have their own view"
  end

  test "a supervisor with an unresolved child list is visible in the tree" do
    # Regression, found by scanning Plausible. Its Supervisor.start_link takes
    # `List.flatten(children)` — a function call, outside the binding bound — so
    # the child list is correctly unresolved and the supervisor has no edges.
    #
    # `tree/1` derived roots from edge SOURCES, so that supervisor vanished
    # entirely: the endpoint returned `supervisor_count: 1, roots: []`. A
    # consumer sees an empty tree with nothing to distinguish "supervises
    # nothing" from "we could not see the children" — the gap-presented-as-fact
    # the flag exists to prevent.
    decls = [
      %{
        key: "Opaque.Supervisor",
        module: "Opaque.Application",
        registered_name: "Opaque.Supervisor",
        dynamic: false,
        strategy: "one_for_one",
        children: [],
        children_unresolved: true
      }
    ]

    view = Giulia.Knowledge.Supervision.tree_from_declarations(decls)

    assert [root] = view.roots, "an unresolved supervisor must still appear as a root"
    assert root.key == "Opaque.Supervisor"
    assert root.children == []
    assert root.children_unresolved == true
  end

  test "a resolved supervisor carries no unresolved flag" do
    decls = [
      %{
        key: "Clear.Supervisor",
        module: "Clear.Application",
        registered_name: "Clear.Supervisor",
        dynamic: false,
        strategy: "one_for_one",
        children: [
          %{key: "Clear.Child", module: "Clear.Child", restart: :permanent, order: 0, conditional: false}
        ],
        children_unresolved: false
      }
    ]

    view = Giulia.Knowledge.Supervision.tree_from_declarations(decls)

    assert [root] = view.roots
    refute Map.has_key?(root, :children_unresolved),
           "the flag must be absent when resolved, never false — no third state to interpret"
  end

  test "a graph of only supervision edges yields a usable view, not a crash", %{project: project} do
    # The degenerate case: every edge filtered out. It must still answer.
    seed!(project, [
      {"Sup", "Child", {:supervises, %{restart: :permanent, order: 0, strategy: "one_for_one", conditional: false}}}
    ])

    assert {:ok, view} = Store.topology_view(project)
    assert view.edges == []
    assert view.edge_count == 0
  end
end
