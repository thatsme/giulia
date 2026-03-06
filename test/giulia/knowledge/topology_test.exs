defmodule Giulia.Knowledge.TopologyTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Topology

  setup do
    # Build a small directed graph:
    #   A -> B -> C
    #   A -> D
    #   D -> C
    graph =
      Graph.new(type: :directed)
      |> Graph.add_vertex("A", :module)
      |> Graph.add_vertex("B", :module)
      |> Graph.add_vertex("C", :module)
      |> Graph.add_vertex("D", :module)
      |> Graph.add_vertex("A.func/1", :function)
      |> Graph.add_edge("A", "B")
      |> Graph.add_edge("B", "C")
      |> Graph.add_edge("A", "D")
      |> Graph.add_edge("D", "C")
      |> Graph.add_edge("A.func/1", "B")

    %{graph: graph}
  end

  # ============================================================================
  # stats/1
  # ============================================================================

  describe "stats/1" do
    test "returns vertex and edge counts", %{graph: graph} do
      result = Topology.stats(graph)
      assert result.vertices == 5
      assert result.edges == 5
      assert is_integer(result.components)
    end

    test "counts type categories", %{graph: graph} do
      result = Topology.stats(graph)
      assert result.type_counts.modules == 4
      assert result.type_counts.functions == 1
    end

    test "identifies hubs by degree", %{graph: graph} do
      result = Topology.stats(graph)
      assert is_list(result.hubs)
      # A has most connections (out to B, D + function edge)
      hub_names = Enum.map(result.hubs, fn {name, _degree} -> name end)
      assert "A" in hub_names or "C" in hub_names
    end

    test "handles empty graph" do
      result = Topology.stats(Graph.new(type: :directed))
      assert result.vertices == 0
      assert result.edges == 0
    end
  end

  # ============================================================================
  # centrality/2
  # ============================================================================

  describe "centrality/2" do
    test "returns in/out degree", %{graph: graph} do
      {:ok, c} = Topology.centrality(graph, "C")
      # C has 2 incoming (B, D), 0 outgoing
      assert c.in_degree == 2
      assert c.out_degree == 0
    end

    test "returns error for missing vertex", %{graph: graph} do
      assert {:error, {:not_found, "Z"}} = Topology.centrality(graph, "Z")
    end
  end

  # ============================================================================
  # dependents/2 and dependencies/2
  # ============================================================================

  describe "dependents/2" do
    test "returns who depends on the module", %{graph: graph} do
      {:ok, deps} = Topology.dependents(graph, "C")
      assert "B" in deps
      assert "D" in deps
    end

    test "returns error for missing module", %{graph: graph} do
      assert {:error, {:not_found, "Z"}} = Topology.dependents(graph, "Z")
    end
  end

  describe "dependencies/2" do
    test "returns what the module depends on", %{graph: graph} do
      {:ok, deps} = Topology.dependencies(graph, "A")
      assert "B" in deps
      assert "D" in deps
    end

    test "returns empty for leaf module", %{graph: graph} do
      {:ok, deps} = Topology.dependencies(graph, "C")
      assert deps == []
    end
  end

  # ============================================================================
  # impact_map/3
  # ============================================================================

  describe "impact_map/3" do
    test "returns upstream and downstream", %{graph: graph} do
      {:ok, result} = Topology.impact_map(graph, "B", 2)
      assert result.vertex == "B"

      upstream_names = Enum.map(result.upstream, fn {name, _depth} -> name end)
      downstream_names = Enum.map(result.downstream, fn {name, _depth} -> name end)

      # B depends on C (upstream = outgoing)
      assert "C" in upstream_names
      # A depends on B (downstream = incoming)
      assert "A" in downstream_names
    end

    test "respects depth limit", %{graph: graph} do
      {:ok, result} = Topology.impact_map(graph, "A", 1)
      upstream_names = Enum.map(result.upstream, fn {name, _depth} -> name end)
      # At depth 1, A -> B and A -> D, but not C (depth 2)
      assert "B" in upstream_names
      assert "D" in upstream_names
      refute "C" in upstream_names
    end

    test "returns fuzzy matches for missing vertex", %{graph: graph} do
      {:error, {:not_found, "Z", matches, info}} = Topology.impact_map(graph, "Z", 2)
      assert is_list(matches)
      assert is_map(info)
    end
  end

  # ============================================================================
  # trace_path/3
  # ============================================================================

  describe "trace_path/3" do
    test "finds shortest path", %{graph: graph} do
      {:ok, path} = Topology.trace_path(graph, "A", "C")
      assert is_list(path)
      assert hd(path) == "A"
      assert List.last(path) == "C"
    end

    test "returns :no_path when unreachable", %{graph: graph} do
      {:ok, :no_path} = Topology.trace_path(graph, "C", "A")
    end

    test "returns error for missing source", %{graph: graph} do
      assert {:error, {:not_found, "Z"}} = Topology.trace_path(graph, "Z", "A")
    end

    test "returns error for missing target", %{graph: graph} do
      assert {:error, {:not_found, "Z"}} = Topology.trace_path(graph, "A", "Z")
    end
  end

  # ============================================================================
  # cycles/1
  # ============================================================================

  describe "cycles/1" do
    test "returns empty for acyclic graph", %{graph: graph} do
      {:ok, result} = Topology.cycles(graph)
      assert result.count == 0
      assert result.cycles == []
    end

    test "detects cycles" do
      cyclic =
        Graph.new(type: :directed)
        |> Graph.add_vertex("X", :module)
        |> Graph.add_vertex("Y", :module)
        |> Graph.add_edge("X", "Y")
        |> Graph.add_edge("Y", "X")

      {:ok, result} = Topology.cycles(cyclic)
      assert result.count == 1
      assert length(hd(result.cycles)) == 2
    end
  end
end
