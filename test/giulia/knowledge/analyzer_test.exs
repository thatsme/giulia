defmodule Giulia.Knowledge.AnalyzerTest do
  @moduledoc """
  Tests for Knowledge.Analyzer — pure analytical functions on Graph.t().

  All functions are stateless: they take a graph and return computed metrics.
  Tests build small graphs inline and verify the analytics.
  """
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Analyzer

  # ============================================================================
  # Helpers: Build test graphs
  # ============================================================================

  # Simple linear graph: A -> B -> C
  defp linear_graph do
    Graph.new(type: :directed)
    |> Graph.add_vertex("A", :module)
    |> Graph.add_vertex("B", :module)
    |> Graph.add_vertex("C", :module)
    |> Graph.add_edge("A", "B", label: :depends_on)
    |> Graph.add_edge("B", "C", label: :depends_on)
  end

  # Star graph: Hub with multiple dependents
  # D1, D2, D3 all depend on Hub
  defp star_graph do
    Graph.new(type: :directed)
    |> Graph.add_vertex("Hub", :module)
    |> Graph.add_vertex("D1", :module)
    |> Graph.add_vertex("D2", :module)
    |> Graph.add_vertex("D3", :module)
    |> Graph.add_edge("D1", "Hub", label: :depends_on)
    |> Graph.add_edge("D2", "Hub", label: :depends_on)
    |> Graph.add_edge("D3", "Hub", label: :depends_on)
  end

  # Diamond: A -> B, A -> C, B -> D, C -> D
  defp diamond_graph do
    Graph.new(type: :directed)
    |> Graph.add_vertex("A", :module)
    |> Graph.add_vertex("B", :module)
    |> Graph.add_vertex("C", :module)
    |> Graph.add_vertex("D", :module)
    |> Graph.add_edge("A", "B", label: :depends_on)
    |> Graph.add_edge("A", "C", label: :depends_on)
    |> Graph.add_edge("B", "D", label: :depends_on)
    |> Graph.add_edge("C", "D", label: :depends_on)
  end

  # Cycle: A -> B -> C -> A
  defp cyclic_graph do
    Graph.new(type: :directed)
    |> Graph.add_vertex("A", :module)
    |> Graph.add_vertex("B", :module)
    |> Graph.add_vertex("C", :module)
    |> Graph.add_edge("A", "B", label: :depends_on)
    |> Graph.add_edge("B", "C", label: :depends_on)
    |> Graph.add_edge("C", "A", label: :depends_on)
  end

  # Graph with function vertices and call edges
  defp function_graph do
    Graph.new(type: :directed)
    |> Graph.add_vertex("Alpha", :module)
    |> Graph.add_vertex("Beta", :module)
    |> Graph.add_vertex("Alpha.run/1", :function)
    |> Graph.add_vertex("Alpha.helper/0", :function)
    |> Graph.add_vertex("Beta.process/2", :function)
    |> Graph.add_edge("Alpha", "Beta", label: :depends_on)
    |> Graph.add_edge("Alpha.run/1", "Beta.process/2", label: :calls)
    |> Graph.add_edge("Alpha.run/1", "Alpha.helper/0", label: :calls)
  end

  # Graph with behaviour/implements edges
  defp behaviour_graph do
    Graph.new(type: :directed)
    |> Graph.add_vertex("Provider", :behaviour)
    |> Graph.add_vertex("CloudProvider", :module)
    |> Graph.add_vertex("LocalProvider", :module)
    |> Graph.add_edge("CloudProvider", "Provider", label: :implements)
    |> Graph.add_edge("LocalProvider", "Provider", label: :implements)
  end

  # Empty graph
  defp empty_graph do
    Graph.new(type: :directed)
  end

  # ============================================================================
  # stats/1
  # ============================================================================

  describe "stats/1" do
    test "returns vertex and edge counts" do
      result = Analyzer.stats(linear_graph())
      assert result.vertices == 3
      assert result.edges == 2
    end

    test "counts vertex types correctly" do
      result = Analyzer.stats(function_graph())
      assert result.type_counts.modules >= 2
      assert result.type_counts.functions >= 3
    end

    test "identifies hub modules" do
      result = Analyzer.stats(star_graph())
      hubs = result.hubs
      # Hub should be the top hub (3 in-neighbors)
      assert length(hubs) > 0
      {top_hub, _degree} = hd(hubs)
      assert top_hub == "Hub"
    end

    test "empty graph returns zeroes" do
      result = Analyzer.stats(empty_graph())
      assert result.vertices == 0
      assert result.edges == 0
      assert result.components == 0
    end

    test "counts components correctly" do
      # Two isolated modules = 2 components
      graph =
        Graph.new(type: :directed)
        |> Graph.add_vertex("X", :module)
        |> Graph.add_vertex("Y", :module)

      result = Analyzer.stats(graph)
      assert result.components == 2
    end
  end

  # ============================================================================
  # centrality/2
  # ============================================================================

  describe "centrality/2" do
    test "returns in/out degree for hub module" do
      assert {:ok, info} = Analyzer.centrality(star_graph(), "Hub")
      assert info.in_degree == 3
      assert info.out_degree == 0
      assert length(info.dependents) == 3
    end

    test "leaf module has zero in-degree" do
      assert {:ok, info} = Analyzer.centrality(star_graph(), "D1")
      assert info.in_degree == 0
      assert info.out_degree == 1
    end

    test "returns error for unknown vertex" do
      assert {:error, :not_found} = Analyzer.centrality(star_graph(), "NonExistent")
    end

    test "middle node in linear graph" do
      assert {:ok, info} = Analyzer.centrality(linear_graph(), "B")
      assert info.in_degree == 1   # A depends on B
      assert info.out_degree == 1  # B depends on C
    end
  end

  # ============================================================================
  # dependents/2 and dependencies/2
  # ============================================================================

  describe "dependents/2" do
    test "returns modules that depend on target" do
      assert {:ok, deps} = Analyzer.dependents(star_graph(), "Hub")
      assert length(deps) == 3
      assert "D1" in deps
      assert "D2" in deps
      assert "D3" in deps
    end

    test "leaf module has no dependents" do
      assert {:ok, deps} = Analyzer.dependents(linear_graph(), "A")
      assert deps == []
    end

    test "returns error for unknown module" do
      assert {:error, {:not_found, "Ghost"}} = Analyzer.dependents(linear_graph(), "Ghost")
    end
  end

  describe "dependencies/2" do
    test "returns modules that target depends on" do
      assert {:ok, deps} = Analyzer.dependencies(linear_graph(), "A")
      assert deps == ["B"]
    end

    test "end-of-chain module has no dependencies" do
      assert {:ok, deps} = Analyzer.dependencies(linear_graph(), "C")
      assert deps == []
    end

    test "returns error for unknown module" do
      assert {:error, {:not_found, "Ghost"}} = Analyzer.dependencies(linear_graph(), "Ghost")
    end
  end

  # ============================================================================
  # impact_map/3
  # ============================================================================

  describe "impact_map/3" do
    test "returns upstream and downstream at depth" do
      assert {:ok, result} = Analyzer.impact_map(diamond_graph(), "B", 2)
      assert result.vertex == "B"
      # Upstream: B depends on D
      upstream_ids = Enum.map(result.upstream, fn {v, _depth} -> v end)
      assert "D" in upstream_ids
      # Downstream: A depends on B
      downstream_ids = Enum.map(result.downstream, fn {v, _depth} -> v end)
      assert "A" in downstream_ids
    end

    test "depth 1 limits traversal" do
      assert {:ok, result} = Analyzer.impact_map(linear_graph(), "B", 1)
      upstream_ids = Enum.map(result.upstream, fn {v, _d} -> v end)
      downstream_ids = Enum.map(result.downstream, fn {v, _d} -> v end)
      assert "C" in upstream_ids
      assert "A" in downstream_ids
    end

    test "returns function edges for modules with functions" do
      assert {:ok, result} = Analyzer.impact_map(function_graph(), "Alpha", 1)
      # function_edges should contain Alpha's function call info
      assert is_list(result.function_edges)
    end

    test "returns fuzzy suggestions for unknown vertex" do
      assert {:error, {:not_found, "Alph", matches, _meta}} =
               Analyzer.impact_map(function_graph(), "Alph", 2)
      assert is_list(matches)
      # "Alpha" should fuzzy-match "Alph"
      assert "Alpha" in matches
    end
  end

  # ============================================================================
  # trace_path/3
  # ============================================================================

  describe "trace_path/3" do
    test "finds path in linear graph" do
      assert {:ok, path} = Analyzer.trace_path(linear_graph(), "A", "C")
      assert is_list(path)
      assert hd(path) == "A"
      assert List.last(path) == "C"
    end

    test "returns :no_path when unreachable" do
      assert {:ok, :no_path} = Analyzer.trace_path(linear_graph(), "C", "A")
    end

    test "returns error for unknown source" do
      assert {:error, {:not_found, "Ghost"}} = Analyzer.trace_path(linear_graph(), "Ghost", "A")
    end

    test "returns error for unknown destination" do
      assert {:error, {:not_found, "Ghost"}} = Analyzer.trace_path(linear_graph(), "A", "Ghost")
    end

    test "same source and destination returns :no_path (no self-loop)" do
      # Dijkstra from A to A with no self-loop returns no path
      assert {:ok, :no_path} = Analyzer.trace_path(linear_graph(), "A", "A")
    end
  end

  # ============================================================================
  # cycles/1
  # ============================================================================

  describe "cycles/1" do
    test "detects circular dependency" do
      assert {:ok, result} = Analyzer.cycles(cyclic_graph())
      assert result.count > 0
      cycle = hd(result.cycles)
      assert "A" in cycle
      assert "B" in cycle
      assert "C" in cycle
    end

    test "no cycles in acyclic graph" do
      assert {:ok, result} = Analyzer.cycles(linear_graph())
      assert result.count == 0
      assert result.cycles == []
    end

    test "diamond is not a cycle" do
      assert {:ok, result} = Analyzer.cycles(diamond_graph())
      assert result.count == 0
    end

    test "empty graph has no cycles" do
      assert {:ok, result} = Analyzer.cycles(empty_graph())
      assert result.count == 0
    end
  end

  # ============================================================================
  # logic_flow/4 (function-level path)
  # ============================================================================

  describe "logic_flow/4" do
    test "finds function-call path" do
      # Alpha.run/1 calls Beta.process/2
      graph = function_graph()
      assert {:ok, result} = Analyzer.logic_flow(graph, "unused_path", "Alpha.run/1", "Beta.process/2")
      assert is_list(result)
      assert length(result) == 2
    end

    test "returns :no_path when no function call chain exists" do
      graph = function_graph()
      assert {:ok, :no_path} = Analyzer.logic_flow(graph, "unused_path", "Beta.process/2", "Alpha.run/1")
    end

    test "returns error for unknown MFA" do
      graph = function_graph()
      assert {:error, {:not_found, "Nope.func/0"}} =
               Analyzer.logic_flow(graph, "unused_path", "Nope.func/0", "Alpha.run/1")
    end
  end

  # ============================================================================
  # Fuzzy matching (internal but exercised via impact_map)
  # ============================================================================

  describe "fuzzy matching via impact_map" do
    test "typo returns suggestions with fuzzy match" do
      graph =
        Graph.new(type: :directed)
        |> Graph.add_vertex("Giulia.Tools.Registry", :module)
        |> Graph.add_vertex("Giulia.Tools.ReadFile", :module)

      # Typo in name — vertex doesn't exist, should get fuzzy suggestions
      assert {:error, {:not_found, "Giulia.Tools.Registy", matches, _}} =
               Analyzer.impact_map(graph, "Giulia.Tools.Registy", 1)
      assert is_list(matches)
      assert "Giulia.Tools.Registry" in matches
    end

    test "partial segment match returns suggestions" do
      graph =
        Graph.new(type: :directed)
        |> Graph.add_vertex("Giulia.Inference.Orchestrator", :module)
        |> Graph.add_vertex("Giulia.Inference.Pool", :module)

      assert {:error, {:not_found, "Orchestrator", matches, _}} =
               Analyzer.impact_map(graph, "Orchestrator", 1)
      assert "Giulia.Inference.Orchestrator" in matches
    end
  end

  # ============================================================================
  # Mixed vertex types
  # ============================================================================

  describe "stats with mixed vertex types" do
    test "counts behaviours correctly" do
      result = Analyzer.stats(behaviour_graph())
      assert result.type_counts.behaviours >= 1
    end

    test "function vertices not counted as modules" do
      result = Analyzer.stats(function_graph())
      assert result.type_counts.modules == 2
      assert result.type_counts.functions == 3
    end
  end
end
