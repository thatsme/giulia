defmodule Giulia.Knowledge.Store.Reader do
  @moduledoc """
  Direct ETS reads for Knowledge Graph queries.

  All functions read the graph and metric caches directly from ETS
  (`:giulia_knowledge_graphs`) without going through the GenServer process.
  This eliminates serialization for read-heavy workloads — all callers
  can read concurrently.

  Write coordination remains in `Giulia.Knowledge.Store` (the GenServer).
  """

  alias Giulia.Knowledge.Analyzer

  @table :giulia_knowledge_graphs

  # ============================================================================
  # Private helpers — ETS access
  # ============================================================================

  defp get_graph(project_path) do
    case :ets.lookup(@table, {:graph, project_path}) do
      [{_, graph}] -> graph
      [] -> Graph.new(type: :directed)
    end
  end

  defp get_cached(project_path, metric) do
    case :ets.lookup(@table, {:metrics, project_path}) do
      [{_, metrics}] -> Map.get(metrics, metric)
      [] -> nil
    end
  end

  defp put_cached(project_path, metric, value) do
    current =
      case :ets.lookup(@table, {:metrics, project_path}) do
        [{_, metrics}] -> metrics
        [] -> %{}
      end

    :ets.insert(@table, {{:metrics, project_path}, Map.put(current, metric, value)})
  end

  # ============================================================================
  # Topology queries (8) — ETS read + Analyzer
  # ============================================================================

  def stats(project_path) do
    project_path |> get_graph() |> Analyzer.stats()
  end

  def centrality(project_path, module) do
    project_path |> get_graph() |> Analyzer.centrality(module)
  end

  def dependents(project_path, module) do
    project_path |> get_graph() |> Analyzer.dependents(module)
  end

  def dependencies(project_path, module) do
    project_path |> get_graph() |> Analyzer.dependencies(module)
  end

  def impact_map(project_path, vertex_id, depth) do
    project_path |> get_graph() |> Analyzer.impact_map(vertex_id, depth)
  end

  def trace_path(project_path, from, to) do
    project_path |> get_graph() |> Analyzer.trace_path(from, to)
  end

  def find_cycles(project_path) do
    project_path |> get_graph() |> Analyzer.cycles()
  end

  def find_fan_in_out(project_path) do
    graph = get_graph(project_path)
    Analyzer.fan_in_out(graph, project_path)
  end

  # ============================================================================
  # Cached metrics (5) — ETS cache-first, cold fallback computes + writes
  # ============================================================================

  def heatmap(project_path) do
    case get_cached(project_path, :heatmap) do
      nil ->
        graph = get_graph(project_path)
        result = Analyzer.heatmap(graph, project_path)
        put_cached(project_path, :heatmap, result)
        result

      cached ->
        cached
    end
  end

  def change_risk_score(project_path) do
    case get_cached(project_path, :change_risk) do
      nil ->
        graph = get_graph(project_path)
        result = Analyzer.change_risk(graph, project_path)
        put_cached(project_path, :change_risk, result)
        result

      cached ->
        cached
    end
  end

  def find_god_modules(project_path) do
    case get_cached(project_path, :god_modules) do
      nil ->
        graph = get_graph(project_path)
        result = Analyzer.god_modules(graph, project_path)
        put_cached(project_path, :god_modules, result)
        result

      cached ->
        cached
    end
  end

  def find_dead_code(project_path) do
    case get_cached(project_path, :dead_code) do
      nil ->
        graph = get_graph(project_path)
        result = Analyzer.dead_code(graph, project_path)
        put_cached(project_path, :dead_code, result)
        result

      cached ->
        cached
    end
  end

  def find_coupling(project_path) do
    case get_cached(project_path, :coupling) do
      nil ->
        result = Analyzer.coupling(project_path)
        put_cached(project_path, :coupling, result)
        result

      cached ->
        cached
    end
  end

  # ============================================================================
  # Non-cached analysis (4) — direct Analyzer call, no graph needed
  # ============================================================================

  def find_orphan_specs(project_path) do
    Analyzer.orphan_specs(project_path)
  end

  def find_api_surface(project_path) do
    Analyzer.api_surface(project_path)
  end

  def style_oracle(project_path, query, top_k) do
    Analyzer.style_oracle(project_path, query, top_k)
  end

  def struct_lifecycle(project_path, struct_module) do
    Analyzer.struct_lifecycle(project_path, struct_module)
  end

  # ============================================================================
  # Graph-dependent analysis (6) — ETS read + Analyzer
  # ============================================================================

  def find_unprotected_hubs(project_path, opts) do
    graph = get_graph(project_path)
    Analyzer.find_unprotected_hubs(graph, project_path, opts)
  end

  def get_test_targets(project_path, module) do
    graph = get_graph(project_path)
    Analyzer.test_targets(graph, module, project_path)
  end

  def check_behaviour_integrity(project_path, behaviour) do
    graph = get_graph(project_path)
    Analyzer.behaviour_integrity(graph, behaviour, project_path)
  end

  def check_all_behaviours(project_path) do
    graph = get_graph(project_path)
    Analyzer.all_behaviours(graph, project_path)
  end

  def logic_flow(project_path, from_mfa, to_mfa) do
    graph = get_graph(project_path)
    Analyzer.logic_flow(graph, project_path, from_mfa, to_mfa)
  end

  def pre_impact_check(project_path, params) do
    graph = get_graph(project_path)
    Analyzer.pre_impact_check(graph, project_path, params)
  end

  # ============================================================================
  # Direct graph operations (2)
  # ============================================================================

  def graph(project_path) do
    get_graph(project_path)
  end

  def get_implementers(project_path, behaviour) do
    graph = get_graph(project_path)

    implementers =
      Graph.in_edges(graph, behaviour)
      |> Enum.filter(fn edge -> edge.label == :implements end)
      |> Enum.map(fn edge -> edge.v1 end)
      |> Enum.uniq()

    {:ok, implementers}
  end
end
