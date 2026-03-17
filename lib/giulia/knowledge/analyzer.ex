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

  @spec stats(Graph.t()) :: map()
  defdelegate stats(graph), to: Giulia.Knowledge.Topology

  @spec centrality(Graph.t(), String.t()) :: {:ok, map()} | {:error, {:not_found, String.t()}}
  defdelegate centrality(graph, module), to: Giulia.Knowledge.Topology

  @spec dependents(Graph.t(), String.t()) :: {:ok, [String.t()]} | {:error, {:not_found, String.t()}}
  defdelegate dependents(graph, module), to: Giulia.Knowledge.Topology

  @spec dependencies(Graph.t(), String.t()) :: {:ok, [String.t()]} | {:error, {:not_found, String.t()}}
  defdelegate dependencies(graph, module), to: Giulia.Knowledge.Topology

  @spec impact_map(Graph.t(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, tuple()}
  defdelegate impact_map(graph, vertex_id, depth), to: Giulia.Knowledge.Topology

  @spec trace_path(Graph.t(), String.t(), String.t()) :: {:ok, :no_path | [String.t()]} | {:error, {:not_found, String.t()}}
  defdelegate trace_path(graph, from, to), to: Giulia.Knowledge.Topology

  @spec cycles(Graph.t()) :: {:ok, map()}
  defdelegate cycles(graph), to: Giulia.Knowledge.Topology

  @spec fan_in_out(Graph.t(), String.t()) :: {:ok, map()}
  defdelegate fan_in_out(graph, project_path), to: Giulia.Knowledge.Topology

  # ============================================================================
  # Metrics (13 functions)
  # ============================================================================

  @spec heatmap(Graph.t(), String.t()) :: {:ok, map()}
  defdelegate heatmap(graph, project_path), to: Giulia.Knowledge.Metrics

  @spec heatmap_with_coupling(Graph.t(), String.t(), map(), map()) :: {:ok, map()}
  defdelegate heatmap_with_coupling(graph, pp, asts, cm), to: Giulia.Knowledge.Metrics

  @spec change_risk(Graph.t(), String.t()) :: {:ok, map()}
  defdelegate change_risk(graph, project_path), to: Giulia.Knowledge.Metrics

  @spec change_risk_with_coupling(Graph.t(), String.t(), map(), map()) :: {:ok, map()}
  defdelegate change_risk_with_coupling(graph, pp, asts, cm), to: Giulia.Knowledge.Metrics

  @spec god_modules(Graph.t(), String.t()) :: {:ok, map()}
  defdelegate god_modules(graph, project_path), to: Giulia.Knowledge.Metrics

  @spec god_modules_impl(Graph.t(), String.t(), map()) :: {:ok, map()}
  defdelegate god_modules_impl(graph, project_path, all_asts), to: Giulia.Knowledge.Metrics

  @spec dead_code(Graph.t(), String.t()) :: {:ok, map()}
  defdelegate dead_code(graph, project_path), to: Giulia.Knowledge.Metrics

  @spec dead_code_with_asts(Graph.t(), String.t(), map()) :: {:ok, map()}
  defdelegate dead_code_with_asts(graph, project_path, all_asts), to: Giulia.Knowledge.Metrics

  @spec coupling(String.t()) :: {:ok, map()}
  defdelegate coupling(project_path), to: Giulia.Knowledge.Metrics

  @spec coupling_from_calls([{String.t(), String.t(), String.t()}]) :: {:ok, map()}
  defdelegate coupling_from_calls(call_triples), to: Giulia.Knowledge.Metrics

  @spec build_coupling_map_from_calls([{String.t(), String.t(), String.t()}]) :: map()
  defdelegate build_coupling_map_from_calls(call_triples), to: Giulia.Knowledge.Metrics

  @spec collect_remote_calls(map()) :: [{String.t(), String.t(), String.t()}]
  defdelegate collect_remote_calls(all_asts), to: Giulia.Knowledge.Metrics

  @spec compute_cached_metrics(Graph.t(), String.t()) :: map()
  defdelegate compute_cached_metrics(graph, project_path), to: Giulia.Knowledge.Metrics

  # ============================================================================
  # Behaviours (2 functions)
  # ============================================================================

  @spec behaviour_integrity(Graph.t(), String.t(), String.t()) ::
          {:ok, :consistent} | {:error, map()}
  defdelegate behaviour_integrity(graph, behaviour, project_path), to: Giulia.Knowledge.Behaviours

  @spec all_behaviours(Graph.t(), String.t()) :: {:ok, :consistent} | {:error, map()}
  defdelegate all_behaviours(graph, project_path), to: Giulia.Knowledge.Behaviours

  # ============================================================================
  # Insights (8 functions)
  # ============================================================================

  @spec orphan_specs(String.t()) :: {:ok, map()}
  defdelegate orphan_specs(project_path), to: Giulia.Knowledge.Insights

  @spec test_targets(Graph.t(), String.t(), String.t()) :: {:ok, map()}
  defdelegate test_targets(graph, module, project_path), to: Giulia.Knowledge.Insights

  @spec logic_flow(Graph.t(), String.t(), String.t(), String.t()) ::
          {:ok, :no_path | [map()]} | {:error, {:not_found, String.t()}}
  defdelegate logic_flow(graph, project_path, from_mfa, to_mfa), to: Giulia.Knowledge.Insights

  @spec style_oracle(String.t(), String.t(), non_neg_integer()) :: {:ok, map()}
  defdelegate style_oracle(project_path, query, top_k), to: Giulia.Knowledge.Insights

  @spec pre_impact_check(Graph.t(), String.t(), map()) :: {:ok, map()} | {:error, tuple()}
  defdelegate pre_impact_check(graph, project_path, params), to: Giulia.Knowledge.Insights

  @spec api_surface(String.t()) :: {:ok, map()}
  defdelegate api_surface(project_path), to: Giulia.Knowledge.Insights

  @spec find_unprotected_hubs(Graph.t(), String.t(), keyword()) :: {:ok, map()}
  defdelegate find_unprotected_hubs(graph, project_path, opts), to: Giulia.Knowledge.Insights

  @spec find_unprotected_hubs(Graph.t(), String.t()) :: {:ok, map()}
  def find_unprotected_hubs(graph, project_path), do: Giulia.Knowledge.Insights.find_unprotected_hubs(graph, project_path, [])

  @spec struct_lifecycle(String.t(), String.t() | nil) :: {:ok, map()}
  defdelegate struct_lifecycle(project_path, struct_module), to: Giulia.Knowledge.Insights

  @spec struct_lifecycle(String.t()) :: {:ok, map()}
  def struct_lifecycle(project_path), do: Giulia.Knowledge.Insights.struct_lifecycle(project_path, nil)
end
