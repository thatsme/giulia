defmodule Giulia.Knowledge.Analyzer do
  @moduledoc """
  Facade for Knowledge Graph analytics.

  Delegates all analytical functions to focused sub-modules:
  - `Topology` — graph stats, centrality, reachability, cycles
  - `Metrics` — heatmap, change risk, god modules, dead code, coupling
  - `Behaviours` — behaviour integrity checking
  - `Insights` — orphan specs, test targets, style oracle, impact checks

  All functions are stateless — they take a `%Graph{}` (and/or `project_path`)
  and return computed metrics. No GenServer, no state mutation.

  Originally a single 1,913-line module, split in Build 108.
  """

  # ============================================================================
  # Topology (8 functions)
  # ============================================================================

  defdelegate stats(graph), to: Giulia.Knowledge.Topology
  defdelegate centrality(graph, module), to: Giulia.Knowledge.Topology
  defdelegate dependents(graph, module), to: Giulia.Knowledge.Topology
  defdelegate dependencies(graph, module), to: Giulia.Knowledge.Topology
  defdelegate impact_map(graph, vertex_id, depth), to: Giulia.Knowledge.Topology
  defdelegate trace_path(graph, from, to), to: Giulia.Knowledge.Topology
  defdelegate cycles(graph), to: Giulia.Knowledge.Topology
  defdelegate fan_in_out(graph, project_path), to: Giulia.Knowledge.Topology

  # ============================================================================
  # Metrics (13 functions)
  # ============================================================================

  defdelegate heatmap(graph, project_path), to: Giulia.Knowledge.Metrics
  defdelegate heatmap_with_coupling(graph, pp, asts, cm), to: Giulia.Knowledge.Metrics
  defdelegate change_risk(graph, project_path), to: Giulia.Knowledge.Metrics
  defdelegate change_risk_with_coupling(graph, pp, asts, cm), to: Giulia.Knowledge.Metrics
  defdelegate god_modules(graph, project_path), to: Giulia.Knowledge.Metrics
  defdelegate god_modules_impl(graph, project_path, all_asts), to: Giulia.Knowledge.Metrics
  defdelegate dead_code(graph, project_path), to: Giulia.Knowledge.Metrics
  defdelegate dead_code_with_asts(graph, project_path, all_asts), to: Giulia.Knowledge.Metrics
  defdelegate coupling(project_path), to: Giulia.Knowledge.Metrics
  defdelegate coupling_from_calls(call_triples), to: Giulia.Knowledge.Metrics
  defdelegate build_coupling_map_from_calls(call_triples), to: Giulia.Knowledge.Metrics
  defdelegate collect_remote_calls(all_asts), to: Giulia.Knowledge.Metrics
  defdelegate compute_cached_metrics(graph, project_path), to: Giulia.Knowledge.Metrics

  # ============================================================================
  # Behaviours (2 functions)
  # ============================================================================

  defdelegate behaviour_integrity(graph, behaviour, project_path), to: Giulia.Knowledge.Behaviours
  defdelegate all_behaviours(graph, project_path), to: Giulia.Knowledge.Behaviours

  # ============================================================================
  # Insights (8 functions)
  # ============================================================================

  defdelegate orphan_specs(project_path), to: Giulia.Knowledge.Insights
  defdelegate test_targets(graph, module, project_path), to: Giulia.Knowledge.Insights
  defdelegate logic_flow(graph, project_path, from_mfa, to_mfa), to: Giulia.Knowledge.Insights
  defdelegate style_oracle(project_path, query, top_k), to: Giulia.Knowledge.Insights
  defdelegate pre_impact_check(graph, project_path, params), to: Giulia.Knowledge.Insights
  defdelegate api_surface(project_path), to: Giulia.Knowledge.Insights

  # find_unprotected_hubs has default opts \\ [] — need explicit /2 wrapper
  defdelegate find_unprotected_hubs(graph, project_path, opts), to: Giulia.Knowledge.Insights
  def find_unprotected_hubs(graph, project_path), do: Giulia.Knowledge.Insights.find_unprotected_hubs(graph, project_path, [])

  # struct_lifecycle has default struct_filter \\ nil — need explicit /1 wrapper
  defdelegate struct_lifecycle(project_path, struct_module), to: Giulia.Knowledge.Insights
  def struct_lifecycle(project_path), do: Giulia.Knowledge.Insights.struct_lifecycle(project_path, nil)
end
