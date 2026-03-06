defmodule Giulia.Knowledge.Topology do
  @moduledoc """
  Graph topology operations for the Knowledge Graph.

  Pure graph traversal functions: statistics, centrality, reachability,
  cycle detection, and path finding. All functions take a `%Graph{}`
  and return computed results — no state mutation.

  Extracted from `Knowledge.Analyzer` (Build 108).
  """

  # ============================================================================
  # Graph Statistics
  # ============================================================================

  def stats(graph) do
    vertices = Graph.vertices(graph)
    vertex_count = length(vertices)
    edge_count = Graph.num_edges(graph)
    components = Graph.components(graph) |> length()

    # Count by type
    type_counts =
      vertices
      |> Enum.reduce(%{modules: 0, functions: 0, structs: 0, behaviours: 0}, fn v, acc ->
        labels = Graph.vertex_labels(graph, v)
        cond do
          :module in labels -> %{acc | modules: acc.modules + 1}
          :function in labels -> %{acc | functions: acc.functions + 1}
          :struct in labels -> %{acc | structs: acc.structs + 1}
          :behaviour in labels -> %{acc | behaviours: acc.behaviours + 1}
          true -> acc
        end
      end)

    # Find hub modules (most connections)
    hubs =
      vertices
      |> Enum.filter(fn v -> Graph.vertex_labels(graph, v) == [:module] end)
      |> Enum.map(fn v ->
        in_degree = length(Graph.in_neighbors(graph, v))
        out_degree = length(Graph.out_neighbors(graph, v))
        {v, in_degree + out_degree}
      end)
      |> Enum.sort_by(fn {_v, degree} -> -degree end)
      |> Enum.take(5)

    %{
      vertices: vertex_count,
      edges: edge_count,
      components: components,
      type_counts: type_counts,
      hubs: hubs
    }
  end

  # ============================================================================
  # Centrality & Neighbors
  # ============================================================================

  def centrality(graph, module) do
    if Graph.has_vertex?(graph, module) do
      dependents = Graph.in_neighbors(graph, module)
      dependencies = Graph.out_neighbors(graph, module)
      {:ok, %{
        in_degree: length(dependents),
        out_degree: length(dependencies),
        dependents: Enum.sort(dependents)
      }}
    else
      {:error, {:not_found, module}}
    end
  end

  def dependents(graph, module) do
    if Graph.has_vertex?(graph, module) do
      # Who points TO this module (incoming edges) = who depends on me
      deps = Graph.in_neighbors(graph, module)
      {:ok, Enum.sort(deps)}
    else
      {:error, {:not_found, module}}
    end
  end

  def dependencies(graph, module) do
    if Graph.has_vertex?(graph, module) do
      # What this module points TO (outgoing edges) = what I depend on
      deps = Graph.out_neighbors(graph, module)
      {:ok, Enum.sort(deps)}
    else
      {:error, {:not_found, module}}
    end
  end

  # ============================================================================
  # Impact Analysis
  # ============================================================================

  def impact_map(graph, vertex_id, depth) do
    if Graph.has_vertex?(graph, vertex_id) do
      # Upstream: what this vertex depends on (follow outgoing edges)
      upstream = collect_reachable(graph, vertex_id, :out, depth)

      # Downstream: what depends on this vertex (follow incoming edges)
      downstream = collect_reachable(graph, vertex_id, :in, depth)

      # Function-level details if this is a module
      function_edges = get_function_edges(graph, vertex_id)

      {:ok, %{
        vertex: vertex_id,
        upstream: upstream,
        downstream: downstream,
        function_edges: function_edges,
        depth: depth
      }}
    else
      # Fuzzy match: find top 5 similar vertices (modules only, not functions)
      vertices = Graph.vertices(graph)

      module_vertices = Enum.filter(vertices, fn v ->
        is_binary(v) and Graph.vertex_labels(graph, v) == [:module]
      end)

      needle = String.downcase(vertex_id)
      matches =
        module_vertices
        |> Enum.map(fn v -> {v, fuzzy_score(String.downcase(v), needle)} end)
        |> Enum.filter(fn {_v, score} -> score > 0 end)
        |> Enum.sort_by(fn {_v, score} -> -score end)
        |> Enum.take(5)
        |> Enum.map(fn {v, _score} -> v end)

      # Graph density check
      v_count = Graph.num_vertices(graph)
      e_count = Graph.num_edges(graph)
      sparse? = e_count < v_count

      {:error, {:not_found, vertex_id, matches, %{sparse: sparse?, vertices: v_count, edges: e_count}}}
    end
  end

  def trace_path(graph, from, to) do
    if not Graph.has_vertex?(graph, from) do
      {:error, {:not_found, from}}
    else
      if not Graph.has_vertex?(graph, to) do
        {:error, {:not_found, to}}
      else
        case Graph.dijkstra(graph, from, to) do
          nil -> {:ok, :no_path}
          path -> {:ok, path}
        end
      end
    end
  end

  # ============================================================================
  # Circular Dependency Detection
  # ============================================================================

  def cycles(graph) do
    # Filter to module-only subgraph (exclude function/struct vertices)
    module_vertices =
      Graph.vertices(graph)
      |> Enum.filter(fn v ->
        labels = Graph.vertex_labels(graph, v)
        :module in labels
      end)

    # Build a module-only subgraph
    module_graph =
      Enum.reduce(module_vertices, Graph.new(type: :directed), fn v, g ->
        g = Graph.add_vertex(g, v)

        # Only add edges between modules (skip function edges)
        Graph.out_neighbors(graph, v)
        |> Enum.filter(fn neighbor -> neighbor in module_vertices end)
        |> Enum.reduce(g, fn neighbor, g2 ->
          Graph.add_edge(g2, v, neighbor)
        end)
      end)

    # Find strongly connected components with > 1 member = cycles
    cycles =
      Graph.strong_components(module_graph)
      |> Enum.filter(fn component -> length(component) > 1 end)
      |> Enum.map(&Enum.sort/1)
      |> Enum.sort_by(fn c -> -length(c) end)

    {:ok, %{cycles: cycles, count: length(cycles)}}
  end

  # ============================================================================
  # Fan-in / Fan-out Analysis
  # ============================================================================

  def fan_in_out(graph, project_path) do
    all_asts = Giulia.Context.Store.all_asts(project_path)

    # Build module -> file lookup
    module_files =
      all_asts
      |> Enum.flat_map(fn {path, data} ->
        (data[:modules] || []) |> Enum.map(fn m -> {m.name, path} end)
      end)
      |> Map.new()

    # Get all module vertices
    module_vertices =
      Graph.vertices(graph)
      |> Enum.filter(fn v -> :module in Graph.vertex_labels(graph, v) end)

    modules =
      module_vertices
      |> Enum.map(fn v ->
        fan_in = length(Graph.in_neighbors(graph, v))
        fan_out = length(Graph.out_neighbors(graph, v))

        %{
          module: v,
          fan_in: fan_in,
          fan_out: fan_out,
          total: fan_in + fan_out,
          file: Map.get(module_files, v, "unknown")
        }
      end)
      |> Enum.sort_by(fn m -> -(m.total) end)

    {:ok, %{modules: modules, count: length(modules)}}
  end

  # --- Private helpers ---

  defp collect_reachable(graph, vertex_id, direction, max_depth) do
    do_collect(graph, [vertex_id], direction, 0, max_depth, %{}, MapSet.new([vertex_id]))
    |> Enum.sort_by(fn {_v, depth} -> depth end)
  end

  defp do_collect(_graph, [], _direction, _current_depth, _max_depth, acc, _visited), do: Map.to_list(acc)
  defp do_collect(_graph, _frontier, _direction, current_depth, max_depth, acc, _visited)
       when current_depth >= max_depth, do: Map.to_list(acc)

  defp do_collect(graph, frontier, direction, current_depth, max_depth, acc, visited) do
    next_depth = current_depth + 1

    neighbors =
      frontier
      |> Enum.flat_map(fn v ->
        case direction do
          :out -> Graph.out_neighbors(graph, v)
          :in -> Graph.in_neighbors(graph, v)
        end
      end)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    new_acc = Enum.reduce(neighbors, acc, fn v, a -> Map.put(a, v, next_depth) end)
    new_visited = Enum.reduce(neighbors, visited, fn v, vs -> MapSet.put(vs, v) end)

    do_collect(graph, neighbors, direction, next_depth, max_depth, new_acc, new_visited)
  end

  defp get_function_edges(graph, module_name) do
    # Find function vertices belonging to this module
    Graph.vertices(graph)
    |> Enum.filter(fn v ->
      is_binary(v) and String.starts_with?(v, module_name <> ".") and
        Graph.vertex_labels(graph, v) == [:function]
    end)
    |> Enum.map(fn func_vertex ->
      targets = Graph.out_neighbors(graph, func_vertex)
      short_name = String.replace_prefix(func_vertex, module_name <> ".", "")
      {short_name, targets}
    end)
    |> Enum.reject(fn {_name, targets} -> targets == [] end)
  end

  # Simple fuzzy scoring: substring match + bonus for matching final segment
  defp fuzzy_score(haystack, needle) do
    cond do
      haystack == needle -> 100
      String.contains?(haystack, needle) -> 50
      last_segment_match?(haystack, needle) -> 30
      segments_overlap?(haystack, needle) -> 10
      true -> 0
    end
  end

  defp last_segment_match?(haystack, needle) do
    h_parts = String.split(haystack, ".")
    n_parts = String.split(needle, ".")
    last_h = List.last(h_parts) || ""
    last_n = List.last(n_parts) || ""
    String.contains?(last_h, last_n) or String.contains?(last_n, last_h)
  end

  defp segments_overlap?(haystack, needle) do
    h_parts = String.split(haystack, ".") |> MapSet.new()
    n_parts = String.split(needle, ".")
    Enum.any?(n_parts, fn part ->
      Enum.any?(h_parts, fn hp -> String.contains?(hp, part) or String.contains?(part, hp) end)
    end)
  end
end
