defmodule Giulia.Knowledge.PartialGraphTest do
  @moduledoc """
  Tests knowledge graph queries when the graph is partially built.

  In production, the graph is rebuilt asynchronously after indexing.
  API requests can arrive while:
  - Only some files have been indexed
  - The graph has vertices but edges haven't been added yet
  - A module references another that hasn't been indexed
  - The graph is completely empty (cold start, no scan yet)

  These tests verify that all Topology and Insights queries
  degrade gracefully rather than crash or return misleading results.
  """
  use ExUnit.Case, async: false

  alias Giulia.Context.Store
  alias Giulia.Context.Store.Query
  alias Giulia.Knowledge.{Topology, Insights}

  setup do
    # Unique project path per test to prevent cross-test pollution
    project = "/tmp/partial_graph_#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.clear_asts(project) end)
    %{project: project}
  end

  # ============================================================================
  # Empty graph (cold start — no scan has happened)
  # ============================================================================

  describe "empty graph queries" do
    test "stats on empty graph" do
      graph = Graph.new()
      result = Topology.stats(graph)
      # stats returns a map directly (not {:ok, map})
      assert is_map(result)
      assert result.vertices == 0
      assert result.edges == 0
    end

    test "dependents on empty graph returns error" do
      graph = Graph.new()
      result = Topology.dependents(graph, "NonExistent")
      assert {:error, {:not_found, "NonExistent"}} = result
    end

    test "centrality on empty graph returns error" do
      graph = Graph.new()
      result = Topology.centrality(graph, "NonExistent")
      assert {:error, {:not_found, "NonExistent"}} = result
    end

    test "impact_map on empty graph returns error" do
      graph = Graph.new()
      result = Topology.impact_map(graph, "NonExistent", 2)
      assert {:error, {:not_found, "NonExistent", _, _}} = result
    end

    test "trace_path on empty graph returns error" do
      graph = Graph.new()
      result = Topology.trace_path(graph, "A", "B")
      # Should return meaningful error, not crash
      assert {:error, _} = result
    end

    test "orphan_specs on empty project returns empty", %{project: project} do
      {:ok, %{orphans: [], count: 0}} = Insights.orphan_specs(project)
    end

    test "api_surface on empty project returns empty", %{project: project} do
      {:ok, %{modules: [], count: 0}} = Insights.api_surface(project)
    end
  end

  # ============================================================================
  # Partially indexed project (some files missing)
  # ============================================================================

  describe "partial index — module references missing module" do
    setup %{project: project} do
      # Index module A that depends on module B, but don't index B
      Store.put_ast(project, "lib/a.ex", %{
        modules: [%{name: "App.A", line: 1, moduledoc: nil}],
        functions: [
          %{name: :call_b, arity: 0, type: :def, line: 3}
        ],
        imports: [%{type: :alias, module: "App.B", line: 2}],
        types: [], specs: [], callbacks: [], optional_callbacks: [],
        structs: [], docs: [], line_count: 10, complexity: 2
      })

      # B is NOT indexed — simulates partial scan
      :ok
    end

    test "list_modules only shows indexed modules", %{project: project} do
      modules = Query.list_modules(project)
      module_names = Enum.map(modules, & &1.name)
      assert "App.A" in module_names
      refute "App.B" in module_names
    end

    test "find_module returns :not_found for unindexed module", %{project: project} do
      assert :not_found = Query.find_module(project, "App.B")
    end

    test "orphan_specs works with partial data", %{project: project} do
      {:ok, result} = Insights.orphan_specs(project)
      # Should not crash — A has no specs, so no orphans
      assert result.count == 0
    end
  end

  # ============================================================================
  # Graph with vertices but no edges (modules indexed, graph not linked)
  # ============================================================================

  describe "graph with vertices only (no edges)" do
    test "centrality returns zero degrees" do
      graph = Graph.new()
        |> Graph.add_vertex("App.A", :module)
        |> Graph.add_vertex("App.B", :module)

      {:ok, result} = Topology.centrality(graph, "App.A")
      assert result.in_degree == 0
      assert result.out_degree == 0
    end

    test "dependents returns empty list" do
      graph = Graph.new()
        |> Graph.add_vertex("App.A", :module)

      {:ok, deps} = Topology.dependents(graph, "App.A")
      assert deps == []
    end

    test "cycles returns empty on acyclic graph" do
      graph = Graph.new()
        |> Graph.add_vertex("App.A", :module)
        |> Graph.add_vertex("App.B", :module)
        |> Graph.add_edge("App.A", "App.B")

      {:ok, result} = Topology.cycles(graph)
      assert result.count == 0
    end
  end

  # ============================================================================
  # Graph queries with stale data (file changed after indexing)
  # ============================================================================

  describe "stale data — Store has old AST, graph references removed function" do
    test "find_function returns empty for removed function", %{project: project} do
      # Index with foo/1
      Store.put_ast(project, "lib/stale.ex", %{
        modules: [%{name: "App.Stale", line: 1, moduledoc: nil}],
        functions: [%{name: :foo, arity: 1, type: :def, line: 3}],
        imports: [], types: [], specs: [], callbacks: [],
        optional_callbacks: [], structs: [], docs: [],
        line_count: 5, complexity: 1
      })

      # Now overwrite with different functions (simulating file edit)
      Store.put_ast(project, "lib/stale.ex", %{
        modules: [%{name: "App.Stale", line: 1, moduledoc: nil}],
        functions: [%{name: :bar, arity: 0, type: :def, line: 3}],
        imports: [], types: [], specs: [], callbacks: [],
        optional_callbacks: [], structs: [], docs: [],
        line_count: 5, complexity: 1
      })

      # foo should no longer be found
      result = Query.find_function(project, :foo, 1)
      assert result == []

      # bar should be found
      result = Query.find_function(project, :bar, 0)
      assert length(result) == 1
    end
  end

  # ============================================================================
  # Knowledge graph with dangling references
  # ============================================================================

  describe "graph with dangling edges" do
    test "impact_map handles vertex with edge to non-existent vertex gracefully" do
      # This can happen if a module is removed but the graph hasn't been rebuilt
      graph = Graph.new()
        |> Graph.add_vertex("App.A", :module)
        |> Graph.add_vertex("App.B", :module)
        |> Graph.add_edge("App.A", "App.B")

      # B exists in graph but not in Store
      {:ok, result} = Topology.impact_map(graph, "App.A", 2)
      # Should return impact data without crashing
      assert is_map(result)
    end

    test "trace_path between connected vertices works" do
      graph = Graph.new()
        |> Graph.add_vertex("App.A", :module)
        |> Graph.add_vertex("App.B", :module)
        |> Graph.add_vertex("App.C", :module)
        |> Graph.add_edge("App.A", "App.B")
        |> Graph.add_edge("App.B", "App.C")

      {:ok, path} = Topology.trace_path(graph, "App.A", "App.C")
      assert is_list(path)
      assert length(path) == 3
    end

    test "trace_path between disconnected vertices" do
      graph = Graph.new()
        |> Graph.add_vertex("App.A", :module)
        |> Graph.add_vertex("App.Z", :module)

      result = Topology.trace_path(graph, "App.A", "App.Z")
      assert {:ok, :no_path} = result
    end
  end
end
