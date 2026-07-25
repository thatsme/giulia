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
